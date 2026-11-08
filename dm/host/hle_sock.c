// Local network play (DM_NET=lan, hle_sock.h): the guest's bsd socket calls on the host's own sockets. Horizon's bsd service takes FreeBSD's values and Darwin is a BSD too:
// sockaddr_in (with sin_len), SOL_SOCKET, the SO_ / IP_ / TCP_ options games use, MSG_PEEK / MSG_DONTWAIT and the poll bits have the same values, so most arguments pass as
// they are. What differs: the errors it reports are Linux's (EAGAIN 11, EINPROGRESS 115, ENETUNREACH 101; Ryujinx's bsd service answers the same LinuxError values), fcntl's
// O_NONBLOCK is Linux's 0x800, SOCK_NONBLOCK / SOCK_CLOEXEC ride in the type, MSG_NOSIGNAL is not Darwin's (SO_NOSIGPIPE on every socket instead), and SO_RCVTIMEO / SO_SNDTIMEO
// take a 16-byte timeval. Super Smash Bros. Ultimate's Pia polls its socket with RecvFrom and reads GetLastErrno: Darwin's EAGAIN (35, Linux's EDEADLK) made it drop the room
// at once (error 2618-0006). The guest gets small descriptors of its own (from 3, a Select fd_set holds 1024), each naming a host descriptor.
// Only the LAN is reachable (dm_net_allowed), and name resolution stays cut (hle_net.c / hle_offline.c), so a game's online features still fail as they did offline.
// iOS forbids broadcasts to an app without Apple's multicast entitlement: a broadcast then goes as unicasts to the room's nodes (hle_ldn.c) and the configured peers
#include "hle.h"
#include "hle_sock.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <poll.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <TargetConditionals.h>
#include <unistd.h>

void dm_guest_blocking(int on);   // hle_thread.c: this guest thread waits in the host (not runnable for the core-peer yield)

// ---------- configuration (read once) ----------
enum { MAX_PEERS = 16, MAX_ROOM = 8 };
static struct {
    int on, nifm, log, unicast, bind_local;
    char ifname[IFNAMSIZ];
    int npeers; uint32_t peer[MAX_PEERS]; uint16_t peer_port[MAX_PEERS];
} C;
static pthread_once_t g_once = PTHREAD_ONCE_INIT;
static int env_flag(const char *k, int dflt) { const char *e = getenv(k); return e && *e ? atoi(e) != 0 : dflt; }
static void net_config(void) {
    const char *e = getenv("DM_NET");
    int want = e && !strcmp(e, "lan");
    C.on = want && !dm_detclock_enabled();
    if (want && !C.on) LOG("net: DM_NET=lan ignored under the deterministic clock");
    if (!C.on) return;
    C.nifm = env_flag("DM_NET_NIFM", 0);
    C.log = env_flag("DM_NET_LOG", 0);
    C.unicast = env_flag("DM_NET_UNICAST", TARGET_OS_IPHONE);
    C.bind_local = env_flag("DM_NET_BIND", 0);
    if ((e = getenv("DM_NET_IF")) && *e) snprintf(C.ifname, sizeof C.ifname, "%s", e);
    for (const char *p = getenv("DM_NET_PEERS"); p && *p && C.npeers < MAX_PEERS; ) {
        char tok[64]; size_t n = strcspn(p, ", ");
        if (n && n < sizeof tok) {
            memcpy(tok, p, n); tok[n] = 0;
            char *colon = strchr(tok, ':'); unsigned port = 0;
            if (colon) { *colon = 0; port = (unsigned)atoi(colon + 1); }
            struct in_addr a;
            if (inet_pton(AF_INET, tok, &a) == 1) { C.peer[C.npeers] = ntohl(a.s_addr); C.peer_port[C.npeers++] = (uint16_t)port; }
            else LOG("net: DM_NET_PEERS entry '%s' is not an IPv4 address, skipped", tok);
        }
        p += n; p += strspn(p, ", ");
    }
    uint32_t ip = 0, mask = 0; dm_net_local(&ip, &mask);
    LOG("net: local network play on: %u.%u.%u.%u/%u.%u.%u.%u%s%s, %d peer(s), broadcasts %s%s", ip >> 24, ip >> 16 & 255, ip >> 8 & 255, ip & 255,
        mask >> 24, mask >> 16 & 255, mask >> 8 & 255, mask & 255, C.ifname[0] ? " on " : "", C.ifname, C.npeers, C.unicast ? "as unicasts" : "allowed",
        C.bind_local ? ", sockets bound to the local address" : "");
    if (!ip) LOG("net: no local IPv4 address yet (no Wi-Fi?); local wireless will find no one");
}
int dm_net_on(void) { pthread_once(&g_once, net_config); return C.on; }
static uint64_t g_devid; static pthread_once_t g_devid_once = PTHREAD_ONCE_INIT;
static void devid_make(void) {
    const char *e = getenv("DM_DEVICE_ID");
    if (e && *e) { g_devid = strtoull(e, NULL, 16); return; }
    char path[1024]; snprintf(path, sizeof path, "%s/Library/nxnative-device-id", getenv("HOME") ?: ".");
    FILE *f = fopen(path, "r");
    if (f) { if (fscanf(f, "%llx", (unsigned long long *)&g_devid) != 1) g_devid = 0; fclose(f); }
    if (g_devid) return;
    arc4random_buf(&g_devid, sizeof g_devid);
    if ((f = fopen(path, "w"))) { fprintf(f, "%016llx\n", (unsigned long long)g_devid); fclose(f); }
    LOG("net: this console's device ID is new: %016llx (%s)", (unsigned long long)g_devid, path);
}
uint64_t dm_device_id(void) { pthread_once(&g_devid_once, devid_make); return g_devid; }
int dm_net_nifm(void) { return dm_net_on() && C.nifm; }
int dm_net_log(void) { return dm_net_on() && C.log; }
int dm_net_unicast(void) { return dm_net_on() && C.unicast; }
int dm_net_peers(uint32_t *ip, uint16_t *port, int max) {
    if (!dm_net_on()) return 0;
    int n = C.npeers < max ? C.npeers : max;
    for (int i = 0; i < n; i++) { ip[i] = C.peer[i]; if (port) port[i] = C.peer_port[i]; }
    return n;
}

int dm_net_local(uint32_t *ip, uint32_t *mask) {
    *ip = 0; *mask = 0;
    struct ifaddrs *list; if (getifaddrs(&list)) return 0;
    for (int pass = 0; pass < 2 && !*ip; pass++)   // pass 0: the named interface, or an en* one; pass 1: any running non-loopback one but a tunnel
        for (struct ifaddrs *a = list; a; a = a->ifa_next) {
            if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET || !(a->ifa_flags & IFF_UP)) continue;
            int lo = (a->ifa_flags & IFF_LOOPBACK) != 0;
            if (C.ifname[0]) { if (strcmp(a->ifa_name, C.ifname)) continue; }
            else if (lo || !(a->ifa_flags & IFF_RUNNING) || (pass == 0 ? strncmp(a->ifa_name, "en", 2) : !strncmp(a->ifa_name, "utun", 4))) continue;
            *ip = ntohl(((struct sockaddr_in *)a->ifa_addr)->sin_addr.s_addr);
            *mask = a->ifa_netmask ? ntohl(((struct sockaddr_in *)a->ifa_netmask)->sin_addr.s_addr) : 0xffffff00u;
            break;
        }
    freeifaddrs(list);
    return *ip != 0;
}

// ---------- the room (hle_ldn.c) and where a guest may send ----------
static pthread_mutex_t g_room_lock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t g_room[MAX_ROOM]; static int g_nroom;
void dm_net_set_room(const uint32_t *ip, int n) {
    pthread_mutex_lock(&g_room_lock);
    g_nroom = n < MAX_ROOM ? n : MAX_ROOM;
    for (int i = 0; i < g_nroom; i++) g_room[i] = ip[i];
    pthread_mutex_unlock(&g_room_lock);
}
static int room_copy(uint32_t *out) {
    pthread_mutex_lock(&g_room_lock); int n = g_nroom; for (int i = 0; i < n; i++) out[i] = g_room[i]; pthread_mutex_unlock(&g_room_lock);
    return n;
}
int dm_net_allowed(uint32_t ip) {
    if ((ip >> 24) == 10 || (ip >> 24) == 127 || (ip >> 20) == (172u << 4 | 1) || (ip >> 16) == (192u << 8 | 168) || (ip >> 16) == (169u << 8 | 254)
        || (ip >> 22) == (100u << 2 | 1) || ip == 0xffffffffu) return 1;   // 172.16/12, 192.168/16, 169.254/16, 100.64/10, the limited broadcast
    for (int i = 0; i < C.npeers; i++) if (C.peer[i] == ip) return 1;
    uint32_t room[MAX_ROOM]; int n = room_copy(room);
    for (int i = 0; i < n; i++) if (room[i] == ip) return 1;
    return 0;
}
static int is_broadcast(uint32_t ip) {
    if (ip == 0xffffffffu) return 1;
    uint32_t me, mask; return dm_net_local(&me, &mask) && mask != 0xffffffffu && (ip & mask) == (me & mask) && (ip | mask) == 0xffffffffu;
}

// ---------- descriptors ----------
enum { MAX_FD = 128, FD_BASE = 3 };
typedef struct { int host; int nonblock, bound, dgram; } sk_t;
static sk_t g_fd[MAX_FD];
static pthread_mutex_t g_fd_lock = PTHREAD_MUTEX_INITIALIZER;
static __thread int t_err;
int dm_sock_errno(void) { return t_err; }
void dm_sock_set_errno(int e) { t_err = e; }
// Darwin's error → the Linux number the guest expects. 1–34 are the same on both; the socket errors from 35 up are not
static int lx_errno(int e) {
    if (e <= 34) return e;
    switch (e) {
    case EAGAIN: return 11; case EINPROGRESS: return 115; case EALREADY: return 114; case ENOTSOCK: return 88; case EDESTADDRREQ: return 89; case EMSGSIZE: return 90;
    case EPROTOTYPE: return 91; case ENOPROTOOPT: return 92; case EPROTONOSUPPORT: return 93; case ESOCKTNOSUPPORT: return 94; case EOPNOTSUPP: return 95;
    case EPFNOSUPPORT: return 96; case EAFNOSUPPORT: return 97; case EADDRINUSE: return 98; case EADDRNOTAVAIL: return 99; case ENETDOWN: return 100;
    case ENETUNREACH: return 101; case ENETRESET: return 102; case ECONNABORTED: return 103; case ECONNRESET: return 104; case ENOBUFS: return 105; case EISCONN: return 106;
    case ENOTCONN: return 107; case ESHUTDOWN: return 108; case ETIMEDOUT: return 110; case ECONNREFUSED: return 111; case EHOSTDOWN: return 112; case EHOSTUNREACH: return 113;
    default: return 5;   // EIO
    }
}
static int fail_at(const char *fn, int e) {   // e is Darwin's; DM_NET_LOG=1 names the call that failed
    t_err = lx_errno(e);
    if (C.log && e != EAGAIN) LOG("net: %s failed, errno %d (guest %d)", fn, e, t_err);
    return -1;
}
#define fail(e) fail_at(__func__, (e))
#define host_err() fail_at(__func__, errno)
#define SK_SOCK_NONBLOCK 0x20000000
#define SK_SOCK_CLOEXEC  0x10000000
#define SK_MSG_NOSIGNAL  0x20000
#define SK_O_NONBLOCK    0x800
// The host descriptor of a guest one, or -1 with EBADF
static int hfd(int s) {
    if (s < FD_BASE || s >= MAX_FD) return fail(EBADF);
    pthread_mutex_lock(&g_fd_lock); int h = g_fd[s].host; pthread_mutex_unlock(&g_fd_lock);
    return h > 0 ? h : fail(EBADF);
}
static int fd_new(int host, int dgram) {
    pthread_mutex_lock(&g_fd_lock);
    for (int s = FD_BASE; s < MAX_FD; s++)
        if (g_fd[s].host <= 0) { g_fd[s] = (sk_t){host, 0, 0, dgram}; pthread_mutex_unlock(&g_fd_lock); return s; }
    pthread_mutex_unlock(&g_fd_lock);
    close(host); return fail(EMFILE);
}
static void netlog_sa(const char *what, int s, const struct sockaddr_in *a) {
    if (!dm_net_log()) return;
    uint32_t ip = ntohl(a->sin_addr.s_addr);
    LOG("net: %s fd %d %u.%u.%u.%u:%u", what, s, ip >> 24, ip >> 16 & 255, ip >> 8 & 255, ip & 255, ntohs(a->sin_port));
}

// Guest sockaddr → host: AF_INET only, sin_len set (the bytes are the same as Darwin's)
static int sa_in(const void *sa, unsigned n, struct sockaddr_in *out) {
    if (!sa || n < 8) return fail(EINVAL);
    memset(out, 0, sizeof *out); memcpy(out, sa, n < sizeof *out ? n : sizeof *out);
    if (out->sin_family != AF_INET) return fail(EAFNOSUPPORT);
    out->sin_len = sizeof *out;
    return 0;
}
static void sa_out(const struct sockaddr_in *a, void *sa, unsigned *n) {
    if (!sa || !n) return;
    unsigned k = *n < sizeof *a ? *n : (unsigned)sizeof *a;
    struct sockaddr_in c = *a; c.sin_len = sizeof c; c.sin_family = AF_INET;
    memcpy(sa, &c, k); *n = sizeof c;
}
// DM_NET_BIND=1 (two instances on one Mac, each on its own address): sockets are bound to the local address instead of any, and a socket the guest never bound gets the
// local address before it sends or connects, so a peer sees each instance by its own address
static int bind_local(int s, int h) {
    uint32_t ip, mask;
    if (!C.bind_local || !dm_net_local(&ip, &mask)) return 0;
    struct sockaddr_in a = {.sin_len = sizeof a, .sin_family = AF_INET, .sin_addr.s_addr = htonl(ip)};
    if (bind(h, (struct sockaddr *)&a, sizeof a)) return host_err();
    pthread_mutex_lock(&g_fd_lock); g_fd[s].bound = 1; pthread_mutex_unlock(&g_fd_lock);
    return 0;
}
static int ensure_bound(int s, int h) {
    pthread_mutex_lock(&g_fd_lock); int b = g_fd[s].bound; pthread_mutex_unlock(&g_fd_lock);
    return b ? 0 : bind_local(s, h);
}

int dm_sock_socket(int family, int type, int proto) {
    int nb = (type & SK_SOCK_NONBLOCK) != 0; type &= ~(SK_SOCK_NONBLOCK | SK_SOCK_CLOEXEC);
    if (family != AF_INET) return fail(EAFNOSUPPORT);
    if (type != SOCK_STREAM && type != SOCK_DGRAM) return fail(EPROTONOSUPPORT);
    int h = socket(AF_INET, type, proto);
    if (h < 0) return host_err();
    int one = 1;
    setsockopt(h, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    fcntl(h, F_SETFD, FD_CLOEXEC);
    if (nb) fcntl(h, F_SETFL, fcntl(h, F_GETFL) | O_NONBLOCK);
    int s = fd_new(h, type == SOCK_DGRAM);
    if (s >= 0) { pthread_mutex_lock(&g_fd_lock); g_fd[s].nonblock = nb; pthread_mutex_unlock(&g_fd_lock); }
    if (dm_net_log()) LOG("net: socket(%s%s) = fd %d", type == SOCK_DGRAM ? "udp" : "tcp", nb ? ", nonblocking" : "", s);
    return s;
}
int dm_sock_bind(int s, const void *sa, unsigned n) {
    int h = hfd(s); struct sockaddr_in a;
    if (h < 0 || sa_in(sa, n, &a)) return -1;
    uint32_t ip, mask;
    if (C.bind_local && a.sin_addr.s_addr == htonl(INADDR_ANY) && dm_net_local(&ip, &mask)) a.sin_addr.s_addr = htonl(ip);
    if (bind(h, (struct sockaddr *)&a, sizeof a)) { netlog_sa("bind failed", s, &a); return host_err(); }
    pthread_mutex_lock(&g_fd_lock); g_fd[s].bound = 1; pthread_mutex_unlock(&g_fd_lock);
    netlog_sa("bind", s, &a);
    return 0;
}
int dm_sock_connect(int s, const void *sa, unsigned n) {
    int h = hfd(s); struct sockaddr_in a;
    if (h < 0 || sa_in(sa, n, &a)) return -1;
    if (!dm_net_allowed(ntohl(a.sin_addr.s_addr))) { netlog_sa("connect refused (not on the LAN)", s, &a); return fail(ENETUNREACH); }
    if (ensure_bound(s, h)) return -1;
    netlog_sa("connect", s, &a);
    dm_guest_blocking(1); int r = connect(h, (struct sockaddr *)&a, sizeof a); int e = errno; dm_guest_blocking(0);
    if (r) { errno = e; return host_err(); }
    return 0;
}
int dm_sock_listen(int s, int backlog) { int h = hfd(s); if (h < 0) return -1; return listen(h, backlog) ? host_err() : 0; }
int dm_sock_accept(int s, void *sa, unsigned *n) {
    int h = hfd(s); if (h < 0) return -1;
    struct sockaddr_in a; socklen_t al = sizeof a;
    dm_guest_blocking(1); int c = accept(h, (struct sockaddr *)&a, &al); int e = errno; dm_guest_blocking(0);
    if (c < 0) { errno = e; return host_err(); }
    int one = 1; setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one); fcntl(c, F_SETFD, FD_CLOEXEC);
    fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK);   // FreeBSD's accept does not pass O_NONBLOCK on; Darwin's does
    int g = fd_new(c, 0);
    if (g >= 0) { pthread_mutex_lock(&g_fd_lock); g_fd[g].bound = 1; pthread_mutex_unlock(&g_fd_lock); sa_out(&a, sa, n); netlog_sa("accept", g, &a); }
    return g;
}
int dm_sock_close(int s) {
    if (s < FD_BASE || s >= MAX_FD) return fail(EBADF);
    pthread_mutex_lock(&g_fd_lock); int h = g_fd[s].host; g_fd[s].host = 0; pthread_mutex_unlock(&g_fd_lock);
    if (h <= 0) return fail(EBADF);
    if (dm_net_log()) LOG("net: close fd %d", s);
    return close(h) ? host_err() : 0;
}
int dm_sock_shutdown(int s, int how) { int h = hfd(s); if (h < 0) return -1; return shutdown(h, how) ? host_err() : 0; }
int dm_sock_getsockname(int s, void *sa, unsigned *n) {
    int h = hfd(s); if (h < 0) return -1;
    if (dm_net_log()) LOG("net: getsockname(fd %d, %u bytes)", s, n ? *n : 0);
    struct sockaddr_in a; socklen_t al = sizeof a;
    if (getsockname(h, (struct sockaddr *)&a, &al)) return host_err();
    sa_out(&a, sa, n); return 0;
}
int dm_sock_getpeername(int s, void *sa, unsigned *n) {
    int h = hfd(s); if (h < 0) return -1;
    struct sockaddr_in a; socklen_t al = sizeof a;
    if (getpeername(h, (struct sockaddr *)&a, &al)) return host_err();
    sa_out(&a, sa, n); return 0;
}
// Horizon's timeval is {s64 seconds, s64 microseconds}; Darwin's {long, int}
static int is_timeo(int level, int opt) { return level == SOL_SOCKET && (opt == SO_RCVTIMEO || opt == SO_SNDTIMEO); }
int dm_sock_setsockopt(int s, int level, int opt, const void *v, unsigned n) {
    int h = hfd(s); if (h < 0) return -1;
    if (dm_net_log()) LOG("net: setsockopt(fd %d, level %#x, option %#x, %u bytes%s%d)", s, level, opt, n, v && n >= 4 ? ", value " : "", v && n >= 4 ? *(const int *)v : 0);
    if (is_timeo(level, opt)) {
        if (!v || n < 16) return fail(EINVAL);
        int64_t t[2]; memcpy(t, v, 16);
        struct timeval tv = {(time_t)t[0], (suseconds_t)t[1]};
        return setsockopt(h, level, opt, &tv, sizeof tv) ? host_err() : 0;
    }
    if (setsockopt(h, level, opt, v, n)) {
        if (errno == ENOPROTOOPT || errno == EINVAL) {   // a Horizon-only option: accepted, as the guest only tunes its socket with it
            if (dm_net_log()) LOG("net: setsockopt(fd %d, level %#x, option %#x) not on this host, ignored", s, level, opt);
            return 0;
        }
        return host_err();
    }
    return 0;
}
int dm_sock_getsockopt(int s, int level, int opt, void *v, unsigned *n) {
    int h = hfd(s); if (h < 0) return -1;
    if (dm_net_log()) LOG("net: getsockopt(fd %d, level %#x, option %#x)", s, level, opt);
    if (is_timeo(level, opt)) {
        if (!v || !n || *n < 16) return fail(EINVAL);
        struct timeval tv; socklen_t l = sizeof tv;
        if (getsockopt(h, level, opt, &tv, &l)) return host_err();
        int64_t t[2] = {tv.tv_sec, tv.tv_usec}; memcpy(v, t, 16); *n = 16; return 0;
    }
    socklen_t l = n ? *n : 0;
    if (getsockopt(h, level, opt, v, &l)) return host_err();
    if (n) *n = l;
    if (level == SOL_SOCKET && opt == SO_ERROR && v && l >= sizeof(int)) *(int *)v = *(int *)v ? lx_errno(*(int *)v) : 0;
    return 0;
}
int dm_sock_fcntl(int s, int cmd, int arg) {
    int h = hfd(s); if (h < 0) return -1;
    if (dm_net_log()) LOG("net: fcntl(fd %d, %d, %#x)", s, cmd, arg);
    if (cmd == F_GETFL) { int f = fcntl(h, F_GETFL); return f < 0 ? host_err() : (f & O_NONBLOCK ? SK_O_NONBLOCK : 0) | (f & O_ACCMODE); }
    if (cmd == F_SETFL) {
        int f = fcntl(h, F_GETFL); if (f < 0) return host_err();
        int nb = (arg & (SK_O_NONBLOCK | O_NONBLOCK)) != 0;   // Linux's bit, or FreeBSD's from a game that passes that
        if (fcntl(h, F_SETFL, nb ? f | O_NONBLOCK : f & ~O_NONBLOCK)) return host_err();
        pthread_mutex_lock(&g_fd_lock); g_fd[s].nonblock = nb; pthread_mutex_unlock(&g_fd_lock);
        return 0;
    }
    return 0;
}

long dm_sock_recv(int s, void *buf, unsigned long n, int flags) { return dm_sock_recvfrom(s, buf, n, flags, NULL, NULL); }
static _Atomic int g_traced;   // DM_NET_LOG=1: the first data calls are logged one by one
static int trace(void) { return dm_net_log() && atomic_fetch_add(&g_traced, 1) < 200; }
long dm_sock_recvfrom(int s, void *buf, unsigned long n, int flags, void *sa, unsigned *sn) {
    int h = hfd(s); if (h < 0) return -1;
    struct sockaddr_in a; socklen_t al = sizeof a; memset(&a, 0, sizeof a);
    dm_guest_blocking(1); ssize_t r = recvfrom(h, buf, n, flags & ~SK_MSG_NOSIGNAL, (struct sockaddr *)&a, &al); int e = errno; dm_guest_blocking(0);
    if (r >= 0 && trace()) { char what[64]; snprintf(what, sizeof what, "recv %zd bytes from", r); netlog_sa(what, s, &a); }
    if (r < 0) { errno = e; return host_err(); }
    if (sa && sn) { if (al >= 8 && a.sin_family == AF_INET) sa_out(&a, sa, sn); else *sn = 0; }
    return r;
}
long dm_sock_send(int s, const void *buf, unsigned long n, int flags) {
    int h = hfd(s); if (h < 0) return -1;
    dm_guest_blocking(1); ssize_t r = send(h, buf, n, flags & ~SK_MSG_NOSIGNAL); int e = errno; dm_guest_blocking(0);
    if (r < 0) { errno = e; return host_err(); }
    return r;
}
// A broadcast where broadcasts are not allowed, or while a room is up: one unicast per room node (else per peer), the same port. Its length when any went out
static long send_fanout(int s, int h, const void *buf, unsigned long n, int flags, const struct sockaddr_in *to) {
    uint32_t dst[MAX_ROOM + MAX_PEERS]; int nd = room_copy(dst);
    if (!nd) nd = dm_net_peers(dst, NULL, MAX_PEERS);
    uint32_t me = 0, mask; dm_net_local(&me, &mask);
    long sent = -1; int e = 0;
    for (int i = 0; i < nd; i++) {
        if (dst[i] == me) continue;
        struct sockaddr_in a = *to; a.sin_addr.s_addr = htonl(dst[i]);
        ssize_t r = sendto(h, buf, n, flags, (struct sockaddr *)&a, sizeof a);
        if (r >= 0) sent = r; else e = errno;
    }
    if (dm_net_log()) LOG("net: broadcast from fd %d to port %u sent as %d unicast(s)", s, ntohs(to->sin_port), nd);
    if (sent < 0 && e) { errno = e; return host_err(); }
    return sent < 0 ? (long)n : sent;   // nobody to send to: dropped, as a broadcast nobody hears
}
long dm_sock_sendto(int s, const void *buf, unsigned long n, int flags, const void *sa, unsigned sn) {
    if (!sa) return dm_sock_send(s, buf, n, flags);
    int h = hfd(s); struct sockaddr_in a;
    if (h < 0 || sa_in(sa, sn, &a)) return -1;
    uint32_t ip = ntohl(a.sin_addr.s_addr);
    flags &= ~SK_MSG_NOSIGNAL;
    if (ensure_bound(s, h)) return -1;
    if (is_broadcast(ip)) {
        uint32_t room[MAX_ROOM];
        if (C.unicast || room_copy(room)) return send_fanout(s, h, buf, n, flags, &a);
        int one = 1; setsockopt(h, SOL_SOCKET, SO_BROADCAST, &one, sizeof one);
    } else if (!dm_net_allowed(ip)) { netlog_sa("sendto refused (not on the LAN)", s, &a); return fail(ENETUNREACH); }
    ssize_t r = sendto(h, buf, n, flags, (struct sockaddr *)&a, sizeof a);
    if (trace()) { char what[64]; snprintf(what, sizeof what, "sendto %lu bytes (result %zd) to", n, r); netlog_sa(what, s, &a); }
    return r < 0 ? host_err() : r;
}

// Poll / Select: the guest's descriptors translated, waited for in the host; an unknown one reports POLLNVAL as the kernel does
int dm_sock_poll(void *fds, uint64_t n, int ms) {
    if (n > 256) return fail(EINVAL);
    sk_pollfd *g = fds; struct pollfd p[256]; int bad = 0;
    for (uint64_t i = 0; i < n; i++) {
        g[i].revents = 0; p[i].fd = -1; p[i].events = g[i].events; p[i].revents = 0;
        if (g[i].fd < 0) continue;
        int h = 0;
        if (g[i].fd >= FD_BASE && g[i].fd < MAX_FD) { pthread_mutex_lock(&g_fd_lock); h = g_fd[g[i].fd].host; pthread_mutex_unlock(&g_fd_lock); }
        if (h > 0) p[i].fd = h; else { g[i].revents = POLLNVAL; bad++; }
    }
    int r = 0;
    if (trace()) LOG("net: poll(%llu descriptor(s), first fd %d, %d ms)", (unsigned long long)n, n ? g[0].fd : -1, ms);
    if (!bad || ms != 0) {
        dm_guest_blocking(1); r = poll(p, (nfds_t)n, bad ? 0 : ms); int e = errno; dm_guest_blocking(0);
        if (r < 0) { errno = e; return host_err(); }
    }
    int ready = 0;
    for (uint64_t i = 0; i < n; i++) { if (p[i].fd >= 0) g[i].revents = p[i].revents; if (g[i].revents) ready++; }
    return ready;
}
int dm_sock_select(int nfds, uint64_t *r, uint64_t *w, uint64_t *e, const int64_t *tv) {
    if (nfds < 0 || nfds > 1024) return fail(EINVAL);
    sk_pollfd p[256]; int fdof[256]; int n = 0;
    uint64_t *sets[3] = {r, w, e}; const int16_t ev[3] = {POLLIN, POLLOUT, POLLPRI};
    for (int fd = 0; fd < nfds; fd++) {
        int16_t want = 0;
        for (int k = 0; k < 3; k++) if (sets[k] && sets[k][fd >> 6] >> (fd & 63) & 1) want |= ev[k];
        if (!want) continue;
        if (n == 256) return fail(EINVAL);
        p[n] = (sk_pollfd){fd, want, 0}; fdof[n++] = fd;
    }
    int ms = tv ? (int)(tv[0] * 1000 + tv[1] / 1000) : -1;
    int got = dm_sock_poll(p, (uint64_t)n, ms);
    if (got < 0) return -1;
    for (int k = 0; k < 3; k++) if (sets[k]) memset(sets[k], 0, (size_t)(nfds + 63) / 64 * 8);
    int count = 0;
    for (int i = 0; i < n; i++) {
        int fd = fdof[i]; int16_t re = p[i].revents;
        if (re & POLLNVAL) return fail(EBADF);
        if (r && re & (POLLIN | POLLHUP | POLLERR)) { r[fd >> 6] |= 1ull << (fd & 63); count++; }
        if (w && re & (POLLOUT | POLLERR)) { w[fd >> 6] |= 1ull << (fd & 63); count++; }
        if (e && re & POLLPRI) { e[fd >> 6] |= 1ull << (fd & 63); count++; }
    }
    return count;
}
