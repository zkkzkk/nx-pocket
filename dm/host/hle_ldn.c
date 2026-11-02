// Local wireless (nn::ldn) over the LAN, with DM_NET=lan (hle_sock.h); without it every call fails as before, and the game finds no one.
// The protocol is ldn_mitm's (github.com/spacemeowx2/ldn_mitm, lan_protocol / lan_discovery), so a room is shared with a Switch running ldn_mitm and with Ryujinx's ldn_mitm mode:
//   UDP port 11452 finds rooms: Scan (empty) to the subnet's broadcast and the peers, ScanResp (the room's NetworkInfo) back to the sender, from a host whose room is up.
//   TCP port 11452 joins one: Connect (the station's NodeInfo) to the host, SyncNetwork (the room's NetworkInfo) from the host to every station whenever the room changes.
//   Each packet: a 12-byte header {u32 magic 0x11451400, u8 type, u8 compressed, u16 length, u16 decompressed length, u8 reserved[2]}, then the body; a compressed body writes
//   each run of zeros as 0x00 and the count of further zeros (up to 255).
// The SDK calls pass the same structs the ldn service takes (NetworkInfo 0x480 bytes, NodeInfo 0x40), so they go on the wire as they are. Addresses inside them (NodeInfo's,
// Ipv4Address) are in host byte order. Once a room is up the game talks to its nodes through its own sockets (hle_sock.c), at the addresses the room lists.
// One host thread (ldn-lan) owns the sockets after Initialize: it answers scans, accepts and reads stations (as host), reads the host's syncs (as station), and signals the
// game's state change event on every change of state or of the room. The game's calls only change state under the lock and send.
// Hosting from an iPhone: iOS lets the app neither send nor receive broadcasts, so an iPhone's scan goes to every address of its subnet instead (and to DM_NET_PEERS), and the
// host answers a scan to its sender. A Switch running ldn_mitm only broadcasts, so it finds no room an iPhone hosts; an iPhone finds and joins the Switch's
#include "hle.h"
#include "hle_sock.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <sys/socket.h>
#include <unistd.h>

void dm_guest_sleep_ns(int64_t ns);
void dm_guest_blocking(int on);

// ---------- the ldn structs (SDK layout = the ldn service's = the wire's) ----------
typedef struct { uint8_t raw[6]; } ldn_mac;
typedef struct { uint8_t len; char raw[33]; } ldn_ssid;
typedef struct { uint64_t local_comm_id; uint8_t _u1[2]; uint16_t scene_id; uint8_t _u2[4]; } ldn_intent;
typedef struct { uint64_t high, low; } ldn_session;
typedef struct { ldn_intent intent; ldn_session session; } ldn_netid;
typedef struct { ldn_mac bssid; ldn_ssid ssid; int16_t channel; int8_t link_level; uint8_t network_type; uint32_t _u; } ldn_common;
typedef struct { uint32_t ip; ldn_mac mac; int8_t node_id; int8_t connected; char user[33]; uint8_t _u1; int16_t local_comm_version; uint8_t _u2[16]; } ldn_node;
typedef struct {
    uint8_t random[16]; uint16_t security_mode; uint8_t accept_policy; uint8_t _u1[3]; uint8_t node_count_max, node_count;
    ldn_node nodes[8]; uint16_t _u2; uint16_t adv_size; uint8_t adv[384]; uint8_t _u3[148];
} ldn_ldninfo;
typedef struct { ldn_netid id; ldn_common common; ldn_ldninfo ldn; } ldn_netinfo;
typedef struct { ldn_intent intent; uint16_t channel; uint8_t node_count_max, _u1; uint16_t local_comm_version; uint8_t _u2[10]; } ldn_netcfg;
typedef struct { uint16_t security_mode, passphrase_size; uint8_t passphrase[64]; } ldn_seccfg;
typedef struct { char user[33]; uint8_t _u[15]; } ldn_usercfg;
typedef struct { uint8_t random[16]; ldn_session session; } ldn_secparam;
typedef struct { ldn_netid id; uint32_t network_type; ldn_mac bssid; ldn_ssid ssid; uint8_t _u[16]; uint32_t flag; } ldn_filter;
_Static_assert(sizeof(ldn_node) == 0x40, "NodeInfo");
_Static_assert(sizeof(ldn_common) == 0x30, "CommonNetworkInfo");
_Static_assert(sizeof(ldn_netinfo) == 0x480, "NetworkInfo");
_Static_assert(sizeof(ldn_netcfg) == 0x20, "NetworkConfig");
_Static_assert(sizeof(ldn_seccfg) == 0x44, "SecurityConfig");
_Static_assert(sizeof(ldn_usercfg) == 0x30, "UserConfig");
_Static_assert(sizeof(ldn_secparam) == 0x20, "SecurityParameter");
_Static_assert(sizeof(ldn_filter) == 0x60, "ScanFilter");
enum { ST_NONE, ST_INIT, ST_AP, ST_AP_UP, ST_STA, ST_STA_UP, ST_ERROR };   // nn::ldn::State
enum { F_LOCAL_COMM_ID = 1, F_SESSION = 2, F_NETWORK_TYPE = 4, F_SSID = 16, F_SCENE = 32 };   // ScanFilter flags
enum { DR_NONE = 0, DR_USER = 1, DR_DESTROYED = 3, DR_SIGNAL_LOST = 6 };                   // DisconnectReason
enum { NODES = 8, STATIONS = 7, MAX_SCAN = 16, DEFAULT_PORT = 11452 };

// ---------- the wire ----------
enum { PK_SCAN, PK_SCAN_RESP, PK_CONNECT, PK_SYNC };
typedef struct { uint32_t magic; uint8_t type, compressed; uint16_t len, raw_len; uint8_t _r[2]; } pk_head;
_Static_assert(sizeof(pk_head) == 12, "LANPacketHeader");
#define PK_MAGIC 0x11451400u
enum { PK_MAX = 2048 };   // ldn_mitm's buffer: a whole packet never exceeds it
// Runs of zeros as {0, further zeros}; -1 when the result would not be shorter
static int pk_compress(const uint8_t *in, int n, uint8_t *out, int cap) {
    int o = 0;
    for (int i = 0; i < n; ) {
        if (o >= cap) return -1;
        uint8_t c = in[i++];
        out[o++] = c;
        if (c) continue;
        int run = 0; while (i < n && !in[i] && run < 255) { run++; i++; }
        if (o >= cap) return -1;
        out[o++] = (uint8_t)run;
    }
    return o < n ? o : -1;
}
static int pk_decompress(const uint8_t *in, int n, uint8_t *out, int cap) {
    int o = 0;
    for (int i = 0; i < n; ) {
        uint8_t c = in[i++];
        if (o >= cap) return -1;
        out[o++] = c;
        if (c) continue;
        if (i >= n) return -1;
        for (int k = in[i++]; k > 0; k--) { if (o >= cap) return -1; out[o++] = 0; }
    }
    return o;
}
static int pk_build(int type, const void *body, int n, uint8_t *buf) {   // → bytes to send
    pk_head h = {PK_MAGIC, (uint8_t)type, 0, (uint16_t)n, 0, {0, 0}};
    int c = n ? pk_compress(body, n, buf + sizeof h, PK_MAX - (int)sizeof h) : -1;
    if (c >= 0) { h.compressed = 1; h.raw_len = (uint16_t)n; h.len = (uint16_t)c; }
    else if (n) memcpy(buf + sizeof h, body, (size_t)n);
    memcpy(buf, &h, sizeof h);
    return (int)sizeof h + h.len;
}
// One whole packet at the start of buf[0, have) → its type and body in out (length *on); returns the bytes it took, 0 when incomplete, -1 when malformed
static int pk_parse(const uint8_t *buf, int have, int *type, uint8_t *out, int *on) {
    if (have < (int)sizeof(pk_head)) return 0;
    pk_head h; memcpy(&h, buf, sizeof h);
    if (h.magic != PK_MAGIC || sizeof h + h.len > PK_MAX) return -1;
    if (have < (int)(sizeof h + h.len)) return 0;
    const uint8_t *b = buf + sizeof h;
    if (h.compressed) { *on = pk_decompress(b, h.len, out, PK_MAX); if (*on != h.raw_len) return -1; }
    else { memcpy(out, b, h.len); *on = h.len; }
    *type = h.type;
    return (int)sizeof h + h.len;
}

// ---------- state ----------
typedef struct { int fd; int slot; int have; uint8_t buf[PK_MAX * 2]; } conn_t;   // a TCP link: a station (host side, slot 1–7) or the host (station side)
static struct {
    pthread_mutex_t lock;
    int state, inited, reason, accept_policy;
    int udp, listen_fd, wake[2];
    conn_t sta[STATIONS], host;
    ldn_netinfo info;                        // the room (host: ours; station: the host's last sync)
    uint32_t my_ip, my_mask; uint16_t port;
    void *event;                             // the game's state change event
    int scanning, nscan; ldn_netinfo scan[MAX_SCAN];
    pthread_t thread; int stop;
} L = {.lock = PTHREAD_MUTEX_INITIALIZER, .udp = -1, .listen_fd = -1, .wake = {-1, -1}};

static int nlog(void) { return dm_net_log(); }
static void ip_str(uint32_t ip, char *s) { snprintf(s, 16, "%u.%u.%u.%u", ip >> 24, ip >> 16 & 255, ip >> 8 & 255, ip & 255); }
static uint16_t peer_port(uint32_t ip) {   // a peer's own port (DM_NET_PEERS ip:port), else the protocol's
    uint32_t p[16]; uint16_t pp[16]; int n = dm_net_peers(p, pp, 16);
    for (int i = 0; i < n; i++) if (p[i] == ip && pp[i]) return pp[i];
    return L.port;
}
static void fake_mac(uint32_t ip, ldn_mac *m) { m->raw[0] = 2; m->raw[1] = 0; memcpy(m->raw + 2, &ip, 4); }   // as ldn_mitm: 02:00 and the address's bytes as stored
static void wake_thread(void) { if (L.wake[1] >= 0) { char c = 0; (void)!write(L.wake[1], &c, 1); } }
static void signal_game(void) { if (L.event) hle_signal_system_event(L.event); }
// The room's addresses for hle_sock.c's broadcasts (lock held)
static void room_publish(void) {
    uint32_t ip[NODES]; int n = 0;
    if (L.state == ST_AP_UP || L.state == ST_STA_UP)
        for (int i = 0; i < NODES; i++) if (L.info.ldn.nodes[i].connected) ip[n++] = L.info.ldn.nodes[i].ip;
    dm_net_set_room(ip, n);
}
static void set_state(int s) {   // lock held
    if (L.state == s) return;
    if (nlog()) LOG("ldn: state %d -> %d", L.state, s);
    L.state = s; room_publish(); signal_game();
}
static int send_all(int fd, const void *p, int n) {
    for (const uint8_t *b = p; n > 0; ) { ssize_t r = send(fd, b, (size_t)n, 0); if (r <= 0) { if (r < 0 && errno == EINTR) continue; return -1; } b += r; n -= (int)r; }
    return 0;
}
static int tcp_packet(int fd, int type, const void *body, int n) { uint8_t buf[PK_MAX]; return send_all(fd, buf, pk_build(type, body, n, buf)); }
static void udp_packet(int type, const void *body, int n, uint32_t ip, uint16_t port) {
    uint8_t buf[PK_MAX]; int len = pk_build(type, body, n, buf);
    struct sockaddr_in a = {.sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(ip)};
    if (sendto(L.udp, buf, (size_t)len, 0, (struct sockaddr *)&a, sizeof a) < 0 && nlog()) { char s[16]; ip_str(ip, s); LOG("ldn: sendto %s:%u failed (errno %d)", s, port, errno); }
}
static int sock_opts(int fd) {
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, sizeof one);
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    return fd;
}
static int bind_port(int fd, uint16_t port) {   // to the local address under DM_NET_BIND (several instances on one Mac), else to any (broadcasts reach it)
    struct sockaddr_in a = {.sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(port)};
    const char *b = getenv("DM_NET_BIND");
    if (b && atoi(b)) a.sin_addr.s_addr = htonl(L.my_ip);
    int one = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    return bind(fd, (struct sockaddr *)&a, sizeof a);
}
static void conn_close(conn_t *c) { if (c->fd >= 0) close(c->fd); c->fd = -1; c->have = 0; }

// ---------- host side ----------
static void host_sync(void) {   // lock held: node count, then the room to every station, then the game's event
    int n = 1;
    for (int i = 0; i < STATIONS; i++) if (L.sta[i].fd >= 0 && L.info.ldn.nodes[i + 1].connected) n++;
    L.info.ldn.node_count = (uint8_t)n;
    for (int i = 0; i < STATIONS; i++)
        if (L.sta[i].fd >= 0 && L.info.ldn.nodes[i + 1].connected && tcp_packet(L.sta[i].fd, PK_SYNC, &L.info, sizeof L.info))
            LOG("ldn: sync to station %d failed", i + 1);
    room_publish(); signal_game();
}
static void station_gone(int i) {   // lock held
    int was = L.info.ldn.nodes[i + 1].connected;
    conn_close(&L.sta[i]);
    L.info.ldn.nodes[i + 1].connected = 0;
    if (was) { char s[16]; ip_str(L.info.ldn.nodes[i + 1].ip, s); LOG("ldn: station %d (%s) left the room", i + 1, s); host_sync(); }
}
static void host_accept(void) {   // lock held
    struct sockaddr_in a; socklen_t al = sizeof a;
    int fd = accept(L.listen_fd, (struct sockaddr *)&a, &al);
    if (fd < 0) return;
    sock_opts(fd);
    int free_slot = -1, count = 0;
    for (int i = 0; i < STATIONS; i++) { if (L.sta[i].fd < 0) { if (free_slot < 0) free_slot = i; } else count++; }
    if (L.accept_policy == 1 || free_slot < 0 || count + 1 >= L.info.ldn.node_count_max) { close(fd); return; }   // RejectAll, or full
    L.sta[free_slot] = (conn_t){.fd = fd, .slot = free_slot + 1};
}
static void host_on_connect(int i, const uint8_t *body, int n) {   // lock held
    if (n != (int)sizeof(ldn_node)) { station_gone(i); return; }
    ldn_node *nd = &L.info.ldn.nodes[i + 1];
    memcpy(nd, body, sizeof *nd);
    nd->node_id = (int8_t)(i + 1); nd->connected = 1;
    char s[16]; ip_str(nd->ip, s);
    LOG("ldn: %.32s (%s) joined the room as node %d", nd->user, s, i + 1);
    host_sync();
}

// ---------- the thread ----------
static void on_udp(void) {   // lock held
    uint8_t buf[PK_MAX], body[PK_MAX]; struct sockaddr_in a; socklen_t al = sizeof a;
    ssize_t r = recvfrom(L.udp, buf, sizeof buf, 0, (struct sockaddr *)&a, &al);
    int type, n;
    if (r <= 0 || pk_parse(buf, (int)r, &type, body, &n) <= 0) return;
    uint32_t from = ntohl(a.sin_addr.s_addr);
    if (type == PK_SCAN && L.state == ST_AP_UP) {
        if (nlog()) { char s[16]; ip_str(from, s); LOG("ldn: scan from %s:%u answered", s, ntohs(a.sin_port)); }
        udp_packet(PK_SCAN_RESP, &L.info, sizeof L.info, from, ntohs(a.sin_port));
    } else if (type == PK_SCAN_RESP && L.scanning && n == (int)sizeof(ldn_netinfo)) {
        const ldn_netinfo *ni = (const ldn_netinfo *)body;
        for (int i = 0; i < L.nscan; i++) if (!memcmp(&L.scan[i].common.bssid, &ni->common.bssid, sizeof ni->common.bssid)) return;
        if (L.nscan < MAX_SCAN) L.scan[L.nscan++] = *ni;
    }
}
// Read a TCP link's packets: as host from a station (Connect), as station from the host (SyncNetwork). 0 = keep, -1 = closed or broken
static int on_tcp(conn_t *c) {   // lock held
    ssize_t r = recv(c->fd, c->buf + c->have, sizeof c->buf - (size_t)c->have, 0);
    if (r <= 0) return r < 0 && (errno == EAGAIN || errno == EINTR) ? 0 : -1;
    c->have += (int)r;
    for (;;) {
        uint8_t body[PK_MAX]; int type, n;
        int took = pk_parse(c->buf, c->have, &type, body, &n);
        if (took < 0) return -1;
        if (!took) return 0;
        memmove(c->buf, c->buf + took, (size_t)(c->have - took)); c->have -= took;
        if (c == &L.host) {
            if (type == PK_SYNC && n == (int)sizeof(ldn_netinfo)) {
                memcpy(&L.info, body, sizeof L.info);
                if (L.state == ST_STA) { LOG("ldn: in the room (%d node(s))", L.info.ldn.node_count); set_state(ST_STA_UP); }
                room_publish(); signal_game();
            }
        } else if (type == PK_CONNECT) host_on_connect(c->slot - 1, body, n);
    }
}
static void *ldn_thread(void *arg) {
    (void)arg;
    pthread_setname_np("ldn-lan");
    for (;;) {
        struct pollfd p[3 + STATIONS]; conn_t *pc[3 + STATIONS]; int n = 0;
        pthread_mutex_lock(&L.lock);
        if (L.stop) { pthread_mutex_unlock(&L.lock); break; }
        p[n] = (struct pollfd){L.wake[0], POLLIN, 0}; pc[n++] = NULL;
        p[n] = (struct pollfd){L.udp, POLLIN, 0}; pc[n++] = NULL;
        if (L.listen_fd >= 0) { p[n] = (struct pollfd){L.listen_fd, POLLIN, 0}; pc[n++] = NULL; }
        for (int i = 0; i < STATIONS; i++) if (L.sta[i].fd >= 0) { p[n] = (struct pollfd){L.sta[i].fd, POLLIN, 0}; pc[n++] = &L.sta[i]; }
        if (L.host.fd >= 0) { p[n] = (struct pollfd){L.host.fd, POLLIN, 0}; pc[n++] = &L.host; }
        pthread_mutex_unlock(&L.lock);
        if (poll(p, (nfds_t)n, 500) <= 0) continue;
        pthread_mutex_lock(&L.lock);
        for (int i = 0; i < n && !L.stop; i++) {
            if (!p[i].revents) continue;
            if (p[i].fd == L.wake[0]) { char b[16]; (void)!read(L.wake[0], b, sizeof b); continue; }
            if (p[i].fd == L.udp) { on_udp(); continue; }
            if (p[i].fd == L.listen_fd) { host_accept(); continue; }
            conn_t *c = pc[i];
            if (!c || c->fd != p[i].fd) continue;   // closed by the game meanwhile
            if (on_tcp(c) == 0) continue;
            if (c == &L.host) {
                conn_close(&L.host);
                if (L.state == ST_STA_UP || L.state == ST_STA) {
                    LOG("ldn: the host closed the room");
                    L.reason = DR_DESTROYED; memset(&L.info, 0, sizeof L.info); set_state(ST_STA);
                }
            } else station_gone(c->slot - 1);
        }
        pthread_mutex_unlock(&L.lock);
    }
    return NULL;
}

// ---------- the game's calls ----------
static int net_up(void) {   // Initialize: the UDP socket, the wake pipe and the thread (lock held)
    if (!dm_net_local(&L.my_ip, &L.my_mask)) { LOG("ldn: no local IPv4 address (Wi-Fi off?): local wireless unavailable"); return -1; }
    const char *e = getenv("DM_LDN_PORT"); L.port = e && atoi(e) > 0 ? (uint16_t)atoi(e) : DEFAULT_PORT;
    L.udp = sock_opts(socket(AF_INET, SOCK_DGRAM, 0));
    int one = 1; setsockopt(L.udp, SOL_SOCKET, SO_BROADCAST, &one, sizeof one); setsockopt(L.udp, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
    if (L.udp < 0 || bind_port(L.udp, L.port)) { LOG("ldn: UDP port %u unavailable (errno %d)", L.port, errno); if (L.udp >= 0) close(L.udp); L.udp = -1; return -1; }
    if (pipe(L.wake)) { close(L.udp); L.udp = -1; return -1; }
    fcntl(L.wake[0], F_SETFL, O_NONBLOCK); fcntl(L.wake[1], F_SETFL, O_NONBLOCK);
    L.host.fd = L.listen_fd = -1;
    for (int i = 0; i < STATIONS; i++) L.sta[i].fd = -1;
    L.stop = 0;
    pthread_create(&L.thread, NULL, ldn_thread, NULL);
    char s[16]; ip_str(L.my_ip, s);
    LOG("ldn: local wireless over the LAN at %s, port %u%s", s, L.port, dm_net_unicast() ? " (no broadcasts: peers only)" : "");
    return 0;
}
static void close_room(void) {   // lock held: as host, the listener and every station; as station, the link to the host
    if (L.listen_fd >= 0) { close(L.listen_fd); L.listen_fd = -1; }
    for (int i = 0; i < STATIONS; i++) conn_close(&L.sta[i]);
    conn_close(&L.host);
    uint16_t adv_size = L.info.ldn.adv_size; uint8_t adv[sizeof L.info.ldn.adv]; memcpy(adv, L.info.ldn.adv, sizeof adv);   // the access point's advertise data outlives its room
    memset(&L.info, 0, sizeof L.info);
    if (L.state == ST_AP || L.state == ST_AP_UP) { memcpy(L.info.ldn.adv, adv, sizeof adv); L.info.ldn.adv_size = adv_size; }
    wake_thread();
}
static void my_node(ldn_node *nd, const ldn_usercfg *u, int ver) {
    memset(nd, 0, sizeof *nd);
    nd->ip = L.my_ip; fake_mac(L.my_ip, &nd->mac); nd->connected = 1; nd->local_comm_version = (int16_t)ver;
    memcpy(nd->user, u->user, sizeof nd->user); nd->user[32] = 0;
}
#define ON (dm_net_on())
#define LDNW "local wireless: over the LAN with DM_NET=lan, else (cut)"
static _Alignas(16) uint8_t g_ev_ldn[0x100];

HLE_FORCE("_ZN2nn3ldn10InitializeEv", "local wireless: over the LAN with DM_NET=lan, else (cut) initialization fails", Result, h_ldn_Init, void) {
    if (!ON) return RES_FAIL;
    pthread_mutex_lock(&L.lock);
    int r = L.inited ? 0 : net_up();
    if (!r && !L.inited) { L.inited = 1; set_state(ST_INIT); }
    pthread_mutex_unlock(&L.lock);
    return r ? RES_FAIL : RES_OK;
}
HLE_FORCE("_ZN2nn3ldn8FinalizeEv", LDNW, void, h_ldn_Fini, void) {
    if (!ON) return;
    pthread_mutex_lock(&L.lock);
    if (!L.inited) { pthread_mutex_unlock(&L.lock); return; }
    close_room(); L.stop = 1; wake_thread(); L.inited = 0; set_state(ST_NONE);
    pthread_t t = L.thread;
    pthread_mutex_unlock(&L.lock);
    pthread_join(t, NULL);
    pthread_mutex_lock(&L.lock);
    close(L.udp); close(L.wake[0]); close(L.wake[1]); L.udp = L.wake[0] = L.wake[1] = -1;
    pthread_mutex_unlock(&L.lock);
}
HLE_FORCE("_ZN2nn3ldn8GetStateEv", "local wireless state (0 none offline)", int, h_ldn_State, void) {
    if (!ON) return 0;
    pthread_mutex_lock(&L.lock); int s = L.state; pthread_mutex_unlock(&L.lock);
    return s;
}
HLE_FORCE("_ZN2nn3ldn22AttachStateChangeEventEPNS_2os15SystemEventTypeE", "local wireless state event: bound, signalled on every change with DM_NET=lan (offline never)", void, h_ldn_Attach, void *ev) {
    hle_rebind_system_event(ev, ON); (void)g_ev_ldn;   // Attach initializes the event each time (hle_rebind_system_event)
    if (ON) { pthread_mutex_lock(&L.lock); L.event = ev; pthread_mutex_unlock(&L.lock); }
}
static Result state_step(int from, int to) {
    if (!ON) return RES_FAIL;
    pthread_mutex_lock(&L.lock);
    Result r = L.state == from ? RES_OK : RES_FAIL;
    if (!r) set_state(to);
    pthread_mutex_unlock(&L.lock);
    return r;
}
HLE_FORCE("_ZN2nn3ldn11OpenStationEv", LDNW, Result, h_ldn_OpenSta, void) { return state_step(ST_INIT, ST_STA); }
HLE_FORCE("_ZN2nn3ldn15OpenAccessPointEv", LDNW, Result, h_ldn_OpenAp, void) { return state_step(ST_INIT, ST_AP); }
static Result close_to_init(int a, int b) {
    if (!ON) return RES_FAIL;
    pthread_mutex_lock(&L.lock);
    Result r = L.state == a || L.state == b ? RES_OK : RES_FAIL;
    if (!r) { close_room(); set_state(ST_INIT); }
    pthread_mutex_unlock(&L.lock);
    return r;
}
HLE_FORCE("_ZN2nn3ldn12CloseStationEv", LDNW, Result, h_ldn_CloseSta, void) { return close_to_init(ST_STA, ST_STA_UP); }
HLE_FORCE("_ZN2nn3ldn16CloseAccessPointEv", LDNW, Result, h_ldn_CloseAp, void) { return close_to_init(ST_AP, ST_AP_UP); }
HLE_FORCE("_ZN2nn3ldn10DisconnectEv", LDNW, Result, h_ldn_Disc, void) {
    if (!ON) return RES_FAIL;
    pthread_mutex_lock(&L.lock);
    Result r = L.state == ST_STA_UP || L.state == ST_STA ? RES_OK : RES_FAIL;
    if (!r) { close_room(); L.reason = DR_USER; set_state(ST_STA); }
    pthread_mutex_unlock(&L.lock);
    return r;
}
HLE_FORCE("_ZN2nn3ldn14DestroyNetworkEv", LDNW, Result, h_ldn_Destroy, void) {
    if (!ON) return RES_FAIL;
    pthread_mutex_lock(&L.lock);
    Result r = L.state == ST_AP_UP ? RES_OK : RES_FAIL;
    if (!r) { close_room(); LOG("ldn: room closed"); set_state(ST_AP); }
    pthread_mutex_unlock(&L.lock);
    return r;
}

// Scan: Scan to the broadcast address (where allowed) and to every peer, then the answers that came in the scan window, filtered
static Result do_scan(ldn_netinfo *out, int *count, int max, const ldn_filter *f) {
    if (count) *count = 0;
    if (!ON) return RES_FAIL;
    pthread_mutex_lock(&L.lock);
    if (L.state == ST_NONE) { pthread_mutex_unlock(&L.lock); return RES_FAIL; }
    L.nscan = 0; L.scanning = 1;
    if (!dm_net_unicast()) udp_packet(PK_SCAN, NULL, 0, L.my_ip | ~L.my_mask, L.port);
    else {   // no broadcasts (iOS): the scan goes to every address of the subnet instead, at most every 2 s and only on a subnet of up to 1,024 addresses (a /24 Wi-Fi: 254 packets)
        static uint64_t last; uint64_t now = now_ns(); uint32_t hosts = ~L.my_mask;
        if (hosts >= 2 && hosts < 1024 && now - last > 2000000000ull) {
            last = now;
            for (uint32_t h = 1; h < hosts; h++) { uint32_t ip = (L.my_ip & L.my_mask) | h; if (ip != L.my_ip) udp_packet(PK_SCAN, NULL, 0, ip, L.port); }
        }
    }
    uint32_t peer[16]; uint16_t pp[16]; int np = dm_net_peers(peer, pp, 16);
    for (int i = 0; i < np; i++) if (peer[i] != L.my_ip || (pp[i] && pp[i] != L.port)) udp_packet(PK_SCAN, NULL, 0, peer[i], pp[i] ? pp[i] : L.port);
    pthread_mutex_unlock(&L.lock);
    const char *e = getenv("DM_LDN_SCAN_MS");
    dm_guest_sleep_ns((int64_t)(e && atoi(e) > 0 ? atoi(e) : 500) * 1000000);
    pthread_mutex_lock(&L.lock);
    L.scanning = 0;
    int n = 0;
    for (int i = 0; i < L.nscan && n < max; i++) {
        const ldn_netinfo *ni = &L.scan[i];
        if (f) {
            if (f->flag & F_LOCAL_COMM_ID && f->id.intent.local_comm_id != ni->id.intent.local_comm_id) continue;
            if (f->flag & F_SESSION && memcmp(&f->id.session, &ni->id.session, sizeof f->id.session)) continue;
            if (f->flag & F_NETWORK_TYPE && f->network_type != ni->common.network_type) continue;
            if (f->flag & F_SSID && memcmp(&f->ssid, &ni->common.ssid, sizeof f->ssid)) continue;
            if (f->flag & F_SCENE && f->id.intent.scene_id != ni->id.intent.scene_id) continue;
        }
        if (out) out[n] = *ni;
        n++;
    }
    if (nlog() || n) LOG("ldn: scan found %d room(s) (%d answer(s))", n, L.nscan);
    pthread_mutex_unlock(&L.lock);
    if (count) *count = n;
    return RES_OK;
}
HLE_FORCE("_ZN2nn3ldn4ScanEPNS0_11NetworkInfoEPiiRKNS0_10ScanFilterEi", "local wireless scan: rooms on the LAN with DM_NET=lan, else (cut) 0 found", Result, h_ldn_Scan, void *out, int *n, int max, const void *f, int ch) {
    (void)ch; Result r = do_scan(out, n, max, f); return ON ? r : RES_FAIL;
}
HLE_FORCE("_ZN2nn3ldn11ScanPrivateEPNS0_11NetworkInfoEPiiRKNS0_10ScanFilterEi", "local wireless scan: rooms on the LAN with DM_NET=lan, else (cut) 0 found", Result, h_ldn_ScanP, void *out, int *n, int max, const void *f, int ch) {
    (void)ch; Result r = do_scan(out, n, max, f); return ON ? r : RES_FAIL;
}

// Create: the room with us as node 0, a fresh session (or the game's, for a private one: the same room again after the host changed), and the TCP listener
static Result do_create(const ldn_netcfg *nc, const ldn_seccfg *sc, const ldn_secparam *sp, const ldn_usercfg *uc) {
    if (!ON) return RES_FAIL;
    pthread_mutex_lock(&L.lock);
    if (L.state != ST_AP) { pthread_mutex_unlock(&L.lock); return RES_FAIL; }
    int fd = sock_opts(socket(AF_INET, SOCK_STREAM, 0));
    if (fd < 0 || bind_port(fd, L.port) || listen(fd, STATIONS)) {
        LOG("ldn: TCP port %u unavailable (errno %d)", L.port, errno); if (fd >= 0) close(fd);
        pthread_mutex_unlock(&L.lock); return RES_FAIL;
    }
    L.listen_fd = fd;
    ldn_netinfo *ni = &L.info;
    uint8_t adv[sizeof ni->ldn.adv]; uint16_t adv_size = ni->ldn.adv_size;   // SetAdvertiseData may come before the room
    memcpy(adv, ni->ldn.adv, sizeof adv);
    memset(ni, 0, sizeof *ni);
    memcpy(ni->ldn.adv, adv, sizeof adv); ni->ldn.adv_size = adv_size;
    ni->id.intent = nc->intent;
    if (sp) { ni->id.session = sp->session; memcpy(ni->ldn.random, sp->random, sizeof ni->ldn.random); }
    else arc4random_buf(&ni->id.session, sizeof ni->id.session), arc4random_buf(ni->ldn.random, sizeof ni->ldn.random);
    fake_mac(L.my_ip, &ni->common.bssid);
    ni->common.ssid.len = 32; memcpy(ni->common.ssid.raw, "1234567812345678" "1234567812345678", 32);   // ldn_mitm's fixed SSID
    ni->common.channel = nc->channel ? (int16_t)nc->channel : 6;
    ni->common.link_level = 3; ni->common.network_type = 2;
    ni->ldn.security_mode = sc->security_mode;
    ni->ldn.accept_policy = (uint8_t)L.accept_policy;
    ni->ldn.node_count_max = nc->node_count_max ? nc->node_count_max : NODES;
    for (int i = 0; i < NODES; i++) ni->ldn.nodes[i].node_id = (int8_t)i;
    my_node(&ni->ldn.nodes[0], uc, nc->local_comm_version);
    ni->ldn.node_count = 1;
    if (L.reason) L.reason = DR_NONE;
    LOG("ldn: room created (game %016llx, scene %u, up to %u players)", (unsigned long long)nc->intent.local_comm_id, nc->intent.scene_id, ni->ldn.node_count_max);
    set_state(ST_AP_UP);
    room_publish();
    wake_thread();
    pthread_mutex_unlock(&L.lock);
    return RES_OK;
}
HLE_FORCE("_ZN2nn3ldn13CreateNetworkERKNS0_13NetworkConfigERKNS0_14SecurityConfigERKNS0_10UserConfigE", LDNW, Result, h_ldn_Create, const void *a, const void *b, const void *c) {
    return do_create(a, b, NULL, c);
}
HLE_FORCE("_ZN2nn3ldn20CreateNetworkPrivateERKNS0_13NetworkConfigERKNS0_14SecurityConfigERKNS0_17SecurityParameterERKNS0_10UserConfigEiPKNS0_12AddressEntryE", LDNW,
          Result, h_ldn_CreateP, const void *a, const void *b, const void *c, const void *d, int n, const void *e) {
    (void)n; (void)e;   // the address entries (who had which address in the room before) do not matter on a LAN: whoever joins brings its own
    return do_create(a, b, c, d);
}

// Connect: TCP to the room's node 0, our NodeInfo, then wait for the host's first SyncNetwork
static Result do_connect(const ldn_netinfo *ni, const ldn_usercfg *uc, int ver) {
    if (!ON) return RES_FAIL;
    pthread_mutex_lock(&L.lock);
    if (L.state != ST_STA || ni->ldn.node_count == 0) { pthread_mutex_unlock(&L.lock); return RES_FAIL; }
    uint32_t host = ni->ldn.nodes[0].ip; uint16_t port = peer_port(host);
    pthread_mutex_unlock(&L.lock);
    char s[16]; ip_str(host, s);
    int fd = sock_opts(socket(AF_INET, SOCK_STREAM, 0));
    const char *b = getenv("DM_NET_BIND");
    if (fd >= 0 && b && atoi(b)) { struct sockaddr_in me = {.sin_len = sizeof me, .sin_family = AF_INET, .sin_addr.s_addr = htonl(L.my_ip)}; bind(fd, (struct sockaddr *)&me, sizeof me); }
    struct sockaddr_in a = {.sin_len = sizeof a, .sin_family = AF_INET, .sin_port = htons(port), .sin_addr.s_addr = htonl(host)};
    dm_guest_blocking(1); int r = fd < 0 ? -1 : connect(fd, (struct sockaddr *)&a, sizeof a); dm_guest_blocking(0);
    if (r) { LOG("ldn: cannot reach the host %s:%u (errno %d)", s, port, errno); if (fd >= 0) close(fd); return RES_FAIL; }
    ldn_node me; my_node(&me, uc, ver);
    pthread_mutex_lock(&L.lock);
    L.host = (conn_t){.fd = fd, .slot = 0};
    L.info = *ni; L.reason = DR_NONE;
    if (tcp_packet(fd, PK_CONNECT, &me, sizeof me)) { conn_close(&L.host); pthread_mutex_unlock(&L.lock); return RES_FAIL; }
    wake_thread();
    pthread_mutex_unlock(&L.lock);
    for (int i = 0; i < 60; i++) {   // up to 3 s for the host's sync
        pthread_mutex_lock(&L.lock); int st = L.state, open = L.host.fd >= 0; pthread_mutex_unlock(&L.lock);
        if (st == ST_STA_UP) { LOG("ldn: joined the room of %.32s (%s)", ni->ldn.nodes[0].user, s); return RES_OK; }
        if (!open) break;
        dm_guest_sleep_ns(50000000);
    }
    LOG("ldn: the host %s did not take us into its room", s);
    pthread_mutex_lock(&L.lock); conn_close(&L.host); memset(&L.info, 0, sizeof L.info); wake_thread(); pthread_mutex_unlock(&L.lock);
    return RES_FAIL;
}
HLE_FORCE("_ZN2nn3ldn7ConnectERKNS0_11NetworkInfoERKNS0_14SecurityConfigERKNS0_10UserConfigEiNS0_13ConnectOptionE", LDNW, Result, h_ldn_Connect,
          const void *a, const void *b, const void *c, int v, int o) {
    (void)b; (void)o; return do_connect(a, c, v);
}
// A private connect names no room, only its game and session: the room with that session is looked for first
HLE_FORCE("_ZN2nn3ldn14ConnectPrivateERKNS0_13NetworkConfigERKNS0_14SecurityConfigERKNS0_17SecurityParameterERKNS0_10UserConfigEiNS0_13ConnectOptionE", LDNW,
          Result, h_ldn_ConnectP, const void *a, const void *b, const void *c, const void *d, int v, int o) {
    (void)b; (void)o;
    if (!ON) return RES_FAIL;
    const ldn_netcfg *nc = a; const ldn_secparam *sp = c;
    ldn_filter f; memset(&f, 0, sizeof f);
    f.id.intent = nc->intent; f.id.session = sp->session; f.flag = F_LOCAL_COMM_ID | F_SESSION;
    static ldn_netinfo found[4]; int n = 0;   // 4.6 KB: off the guest's stack
    for (int tries = 0; tries < 6 && !n; tries++) do_scan(found, &n, 4, &f);
    return n ? do_connect(&found[0], d, v) : RES_FAIL;
}

HLE_FORCE("_ZN2nn3ldn14GetNetworkInfoEPNS0_11NetworkInfoE", LDNW, Result, h_ldn_NetInfo, void *o) {
    if (!ON) return RES_FAIL;
    pthread_mutex_lock(&L.lock);
    Result r = L.state == ST_AP_UP || L.state == ST_STA_UP ? RES_OK : RES_FAIL;
    if (!r) memcpy(o, &L.info, sizeof L.info);
    pthread_mutex_unlock(&L.lock);
    return r;
}
HLE_FORCE("_ZN2nn3ldn14GetIpv4AddressEPNS0_11Ipv4AddressEPNS0_10SubnetMaskE", "local wireless: our LAN address with DM_NET=lan, else (cut)", Result, h_ldn_Ip, uint32_t *a, uint32_t *m) {
    if (a) *a = 0; if (m) *m = 0;
    if (!ON) return RES_FAIL;
    pthread_mutex_lock(&L.lock);
    Result r = L.state >= ST_INIT ? RES_OK : RES_FAIL;
    if (!r) { if (a) *a = L.my_ip; if (m) *m = L.my_mask; }
    pthread_mutex_unlock(&L.lock);
    return r;
}
HLE_FORCE("_ZN2nn3ldn20GetSecurityParameterEPNS0_17SecurityParameterE", LDNW, Result, h_ldn_SecPrm, void *o) {
    if (!ON) return RES_FAIL;
    pthread_mutex_lock(&L.lock);
    Result r = L.state == ST_AP_UP || L.state == ST_STA_UP ? RES_OK : RES_FAIL;
    if (!r) { ldn_secparam *p = o; memcpy(p->random, L.info.ldn.random, sizeof p->random); p->session = L.info.id.session; }
    pthread_mutex_unlock(&L.lock);
    return r;
}
HLE_FORCE("_ZN2nn3ldn16GetNetworkConfigEPNS0_13NetworkConfigE", LDNW, Result, h_ldn_NetCfg, void *o) {
    if (!ON) return RES_FAIL;
    pthread_mutex_lock(&L.lock);
    Result r = L.state == ST_AP_UP || L.state == ST_STA_UP ? RES_OK : RES_FAIL;
    if (!r) {
        ldn_netcfg *c = o; memset(c, 0, sizeof *c);
        c->intent = L.info.id.intent; c->channel = (uint16_t)L.info.common.channel; c->node_count_max = L.info.ldn.node_count_max;
        c->local_comm_version = (uint16_t)L.info.ldn.nodes[0].local_comm_version;
    }
    pthread_mutex_unlock(&L.lock);
    return r;
}
HLE_FORCE("_ZN2nn3ldn16SetAdvertiseDataEPKvm", LDNW, Result, h_ldn_Adv, const void *d, uint64_t n) {
    if (!ON) return RES_FAIL;
    if (n > sizeof L.info.ldn.adv) return RES_FAIL;
    pthread_mutex_lock(&L.lock);
    Result r = L.state == ST_AP || L.state == ST_AP_UP ? RES_OK : RES_FAIL;
    if (!r) {
        memset(L.info.ldn.adv, 0, sizeof L.info.ldn.adv);
        if (d && n) memcpy(L.info.ldn.adv, d, n);
        L.info.ldn.adv_size = (uint16_t)n;
        if (L.state == ST_AP_UP) host_sync();
    }
    pthread_mutex_unlock(&L.lock);
    return r;
}
HLE_FORCE("_ZN2nn3ldn19GetDisconnectReasonEv", "local wireless: why the last room ended (0 offline)", int, h_ldn_DiscReason, void) {
    if (!ON) return 0;
    pthread_mutex_lock(&L.lock); int r = L.reason; pthread_mutex_unlock(&L.lock); return r;
}
HLE_FORCE("_ZN2nn3ldn20AddAcceptFilterEntryENS0_10MacAddressE", "local wireless: the filter is not kept with DM_NET=lan (only RejectAll counts), else (cut)", Result, h_ldn_Filter, uint64_t mac) {
    (void)mac; return ON ? RES_OK : RES_FAIL;
}
HLE_FORCE("_ZN2nn3ldn22SetStationAcceptPolicyENS0_12AcceptPolicyE", LDNW, Result, h_ldn_Policy, int p) {
    if (!ON) return RES_FAIL;
    pthread_mutex_lock(&L.lock); L.accept_policy = p & 0xff; L.info.ldn.accept_policy = (uint8_t)L.accept_policy;
    if (L.state == ST_AP_UP) host_sync();   // the stations' copy of the room follows, as SetAdvertiseData's does
    pthread_mutex_unlock(&L.lock);
    return RES_OK;
}
HLE_FORCE("_ZN2nn3ldn6RejectENS0_11Ipv4AddressE", "local wireless: drops the station at that address with DM_NET=lan, else (cut)", Result, h_ldn_Reject, uint32_t a) {
    if (!ON) return RES_FAIL;
    pthread_mutex_lock(&L.lock);
    Result r = RES_FAIL;
    if (L.state == ST_AP_UP)
        for (int i = 0; i < STATIONS; i++) if (L.sta[i].fd >= 0 && L.info.ldn.nodes[i + 1].ip == a) { station_gone(i); r = RES_OK; }
    pthread_mutex_unlock(&L.lock);
    return r;
}
// Limits how many controllers may stay connected while in a room (the radio is shared on hardware); a LAN room shares nothing
HLE_FORCE("_ZN2nn3ldn32SetWirelessControllerRestrictionENS0_29WirelessControllerRestrictionE", "local wireless: controller restriction, nothing to restrict on the host",
          Result, h_ldn_CtrlRestrict, int r) { (void)r; return ON ? RES_OK : RES_FAIL; }
