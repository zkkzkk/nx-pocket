// Opt-in Open Course World transport. The default host remains offline. Guest socket ABI is
// FreeBSD (libnx external/bsd headers); TLS uses Apple's trust store and hostname validation.
// Configuration is private app data, never a profile constant or a logged header.
#import <Foundation/Foundation.h>
#import <Security/SecureTransport.h>
#include "hle.h"
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdatomic.h>
#include <ifaddrs.h>

static int enabled;
void dm_thread_host_block(int entering);   // hle_thread.c: blocking host I/O gives the guest core back (core_lock)
static void net_block(int entering) { int e = errno; if (entering) dm_host_work++; else dm_host_work--; dm_thread_host_block(entering); errno = e; }
static char token[23];
static __thread int neterr;
static _Atomic unsigned char owned[8192];
static int fail(int e) { neterr = e; return -1; }
static long done(long n) { if (n < 0) neterr = errno; return n; }
static int valid(int s) { return s >= 0 && s < 8192 && atomic_load(&owned[s]); }
static int family(int f) { return f == 28 ? AF_INET6 : f; }
static int guest_family(int f) { return f == AF_INET6 ? 28 : f; }
static __attribute__((used)) int net_socket(int f, int t, int p) {
    if (f != 2 && f != 28) return fail(EAFNOSUPPORT);
    int s = socket(family(f), t & 0xff, p);
    if (s < 0) return (int)done(s);
    if (s >= 8192) { close(s); return fail(EMFILE); }
    atomic_store(&owned[s], 1);
    int one = 1; setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    if (t & 0x20000000) fcntl(s, F_SETFL, O_NONBLOCK);
    return s;
}
static int address(const void *a, unsigned n, struct sockaddr_storage *out) {
    if (!a || n < 2 || n > sizeof *out) return 0;
    memset(out, 0, sizeof *out); memcpy(out, a, n);
    struct sockaddr *s = (void *)out; s->sa_len = n; s->sa_family = family(s->sa_family);
    return s->sa_family == AF_INET || s->sa_family == AF_INET6;
}
static __attribute__((used)) int net_connect(int s, const void *a, unsigned n) {
    if (!valid(s)) return fail(EBADF);
    struct sockaddr_storage addr; if (!address(a, n, &addr)) return fail(EINVAL);
    net_block(1); int r = connect(s, (void *)&addr, n); net_block(0);
    LOG("OCW socket connect fd=%d result=%d error=%d", s, r, r < 0 ? errno : 0);
    return (int)done(r);
}
static __attribute__((used)) int net_bind(int s, const void *a, unsigned n) {
    struct sockaddr_storage addr; if (!valid(s)) return fail(EBADF);
    if (!address(a, n, &addr)) return fail(EINVAL);
    return (int)done(bind(s, (void *)&addr, n));
}
static __attribute__((used)) int net_close(int s) {
    if (!valid(s)) return fail(EBADF);
    atomic_store(&owned[s], 0); return (int)done(close(s));
}
static __attribute__((used)) int net_shutdown(int s, int h) { return valid(s) ? (int)done(shutdown(s, h)) : fail(EBADF); }
static __attribute__((used)) int net_listen(int s, int n) { return valid(s) ? (int)done(listen(s, n)) : fail(EBADF); }
static __attribute__((used)) int net_name(int s, void *a, unsigned *n) {
    if (!valid(s)) return fail(EBADF);
    int r = getsockname(s, a, n); if (!r && a) ((struct sockaddr *)a)->sa_family = guest_family(((struct sockaddr *)a)->sa_family);
    return (int)done(r);
}
static __attribute__((used)) int net_peer(int s, void *a, unsigned *n) {
    if (!valid(s)) return fail(EBADF);
    int r = getpeername(s, a, n); if (!r && a) ((struct sockaddr *)a)->sa_family = guest_family(((struct sockaddr *)a)->sa_family);
    return (int)done(r);
}
static __attribute__((used)) int net_accept(int s, void *a, unsigned *n) {
    if (!valid(s)) return fail(EBADF);
    net_block(1); int r = accept(s, a, n); net_block(0);
    if (r >= 8192) { close(r); return fail(EMFILE); }
    if (r >= 0) { atomic_store(&owned[r], 1); if (a) ((struct sockaddr *)a)->sa_family = guest_family(((struct sockaddr *)a)->sa_family); }
    return (int)done(r);
}
static int flags(int f) { return (f & ~0x20000) | ((f & 0x20000) ? MSG_NOSIGNAL : 0); }
static __attribute__((used)) long net_recv(int s, void *b, unsigned long n, int f) {
    if (!valid(s)) return fail(EBADF);
    net_block(1); long r = recv(s, b, n, flags(f)); net_block(0); return done(r);
}
static __attribute__((used)) long net_send(int s, const void *b, unsigned long n, int f) {
    if (!valid(s)) return fail(EBADF);
    net_block(1); long r = send(s, b, n, flags(f)); net_block(0); return done(r);
}
static __attribute__((used)) long net_sendto(int s, const void *b, unsigned long n, int f, const void *a, unsigned al) {
    struct sockaddr_storage addr; if (!valid(s)) return fail(EBADF);
    if (a && !address(a, al, &addr)) return fail(EINVAL);
    net_block(1); long r = sendto(s, b, n, flags(f), a ? (void *)&addr : NULL, al); net_block(0); return done(r);
}
static __attribute__((used)) long net_recvfrom(int s, void *b, unsigned long n, int f, void *a, unsigned *al) {
    if (!valid(s)) return fail(EBADF);
    net_block(1); long r = recvfrom(s, b, n, flags(f), a, al); net_block(0);
    if (r >= 0 && a) ((struct sockaddr *)a)->sa_family = guest_family(((struct sockaddr *)a)->sa_family);
    return done(r);
}
static __attribute__((used)) int net_fcntl(int s, int c, int arg) { return valid(s) ? (int)done(fcntl(s, c, arg)) : fail(EBADF); }
static __attribute__((used)) int net_setopt(int s, int l, int o, const void *v, unsigned n) {
    if (!valid(s)) return fail(EBADF);
    if (l == 0xffff) l = SOL_SOCKET;
    return (int)done(setsockopt(s, l, o, v, n));
}
static __attribute__((used)) int net_getopt(int s, int l, int o, void *v, unsigned *n) {
    if (!valid(s)) return fail(EBADF);
    if (l == 0xffff) l = SOL_SOCKET;
    return (int)done(getsockopt(s, l, o, v, n));
}
static __attribute__((used)) int net_poll(void *p, unsigned long n, int ms) {
    if (n > 8192) return fail(EINVAL);
    net_block(1); int r = poll(p, (nfds_t)n, ms); net_block(0); return (int)done(r);
}
static __attribute__((used)) int net_errno(void) { return neterr; }
static __attribute__((used)) void net_seterrno(int e) { neterr = e; }
static __attribute__((used)) int net_gai(const char *h, const char *service, const struct addrinfo *hints, struct addrinfo **out) {
    if (!out) return EAI_FAIL; *out = NULL;
    struct addrinfo hint = {0}, *host = NULL;
    if (hints) { hint.ai_flags = hints->ai_flags; hint.ai_family = family(hints->ai_family); hint.ai_socktype = hints->ai_socktype; hint.ai_protocol = hints->ai_protocol; }
    net_block(1); int r = getaddrinfo(h, service, hints ? &hint : NULL, &host); net_block(0);
    LOG("OCW DNS result=%d", r);
    if (r) return r;
    struct addrinfo **tail = out;
    for (struct addrinfo *p = host; p; p = p->ai_next) {
        struct addrinfo *q = calloc(1, sizeof *q); if (!q) { r = EAI_MEMORY; break; }
        *q = *p; q->ai_next = NULL; q->ai_addr = malloc(p->ai_addrlen); q->ai_canonname = p->ai_canonname ? strdup(p->ai_canonname) : NULL;
        if (!q->ai_addr) { free(q->ai_canonname); free(q); r = EAI_MEMORY; break; }
        memcpy(q->ai_addr, p->ai_addr, p->ai_addrlen); q->ai_family = guest_family(p->ai_family); q->ai_addr->sa_family = q->ai_family;
        *tail = q; tail = &q->ai_next;
    }
    freeaddrinfo(host); return r;
}
static __attribute__((used)) void net_freeai(struct addrinfo *p) { while (p) { struct addrinfo *q = p->ai_next; free(p->ai_addr); free(p->ai_canonname); free(p); p = q; } }
static __attribute__((used)) void *net_host(const char *h, const void *options, unsigned long n) {
    (void)options; (void)n; net_block(1); struct hostent *p = gethostbyname(h); net_block(0); return p;
}
static __attribute__((used)) int network_available(void) {
    static _Atomic unsigned calls;
    if (atomic_fetch_add(&calls, 1) < 8) LOG("OCW nifm IsNetworkAvailable -> true");
    return 1;
}
// SDK 7.3.2 sdk+0x319790 returns a bool, not nn::Result. main+0x60e7c4
// stores its low bit as the connection-dialog outcome. Result success (0) cancels it.
static __attribute__((used)) int network_request_result(void) {
    LOG("OCW nifm HandleNetworkRequestErrorResult -> true"); return 1;
}
static __attribute__((used)) void network_submit_wait(void) {
    LOG("OCW nifm SubmitNetworkRequestAndWait: host transport ready");
}
static __attribute__((used)) void nothing(void) {}
static __attribute__((used)) Result ok(void) { return RES_OK; }
static __attribute__((used)) Result ip(uint32_t *out) {
    if (!out) return RES_FAIL;
    *out = 0; struct ifaddrs *list = NULL;
    if (!getifaddrs(&list)) {
        for (struct ifaddrs *p = list; p; p = p->ifa_next) {
            if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET) continue;
            uint32_t a = ((struct sockaddr_in *)p->ifa_addr)->sin_addr.s_addr;
            if ((ntohl(a) >> 24) != 127) { *out = a; break; }
        }
        freeifaddrs(list);
    }
    return *out ? RES_OK : RES_FAIL;
}
// OCW has its own linked identity. Unlike the stock Switch mod's no-op PLT,
// the native service must populate the boolean output (callers initialize it false).
static __attribute__((used)) Result community_account_available(uint8_t *out, const void *handle) {
    (void)handle; if (!out) return RES_FAIL; *out = 1;
    static _Atomic unsigned calls;
    if (atomic_fetch_add(&calls, 1) < 8) LOG("OCW community account available -> true");
    return RES_OK;
}
static __attribute__((used)) Result proxy(void *p) { if (!p) return RES_FAIL; *(uint8_t *)p = 0; return RES_OK; } // nn::nifm::ProxySetting, no proxy
// ParentalControlMgr's worker (main+0xd8c1d4) stores this bool at mgr+0x2a1. The online login
// sequence's State::cCheckParentalControl (main+0x15320e4) returns to cIdle when it is false,
// before cLogin makes any nifm/DNS/socket call. A console without parental controls permits.
static __attribute__((used)) int free_communication(unsigned show_ui) {
    (void)show_ui; static _Atomic unsigned calls;
    if (atomic_fetch_add(&calls, 1) < 8) LOG("OCW pctl CheckFreeCommunicationPermission -> true");
    return 1;
}
// main+0xd44c8 ignores this Result and formats "https://%s/" from the output Fqdn (256 bytes).
// Horizon's nsd passes a name without '%' through unchanged. Only the OCW server resolves;
// every other name still fails, with an empty output instead of uninitialized stack.
static __attribute__((used)) Result resolve(char *out, const char *in) {
    if (!out) return RES_FAIL;
    const char *server = "server.opencourse.world";
    int ok = in && !strncmp(in, server, 256); out[0] = 0;
    static _Atomic unsigned calls;
    if (atomic_fetch_add(&calls, 1) < 8) LOG("OCW nsd ResolveEx -> %s", ok ? server : "refused (not the OCW server)");
    if (!ok) return RES_FAIL;
    memcpy(out, server, strlen(server) + 1); return RES_OK;
}

// C and C++ SSL entry points share the same guest object address. Never place Apple
// pointers into Nintendo's encoded SharedPointer fields (its destructor would release them).
typedef struct { SSLContextRef tls; int fd, mode, want; OSStatus last; char host[256]; } tls_conn;
static __attribute__((used)) Result tls_ctx(void *self, int version) { (void)self; (void)version; return RES_OK; }
static __attribute__((used)) Result tls_ctx_destroy(void *self) { (void)self; return RES_OK; }
static __attribute__((used)) Result tls_id(void *self, uint64_t *id) { if (!self || !id) return RES_FAIL; *id = (uintptr_t)self; return RES_OK; }
static __attribute__((used)) Result tls_import(void *s, uint64_t *id, const char *data, unsigned n, int format) {
    (void)s; (void)data; (void)n; (void)format; if (id) *id = 1; return RES_OK; // Apple trust store replaces the game's CA bundle
}
static OSStatus tls_read_cb(SSLConnectionRef ref, void *data, size_t *len) {
    tls_conn *c = (void *)ref; c->want = POLLIN; ssize_t n = recv(c->fd, data, *len, 0);
    if (n < 0) { *len = 0; return errno == EAGAIN || errno == EWOULDBLOCK ? errSSLWouldBlock : errSSLClosedAbort; }
    size_t want = *len; *len = n; return !n ? errSSLClosedGraceful : (size_t)n < want ? errSSLWouldBlock : noErr;
}
static OSStatus tls_write_cb(SSLConnectionRef ref, const void *data, size_t *len) {
    tls_conn *c = (void *)ref; c->want = POLLOUT; ssize_t n = send(c->fd, data, *len, MSG_NOSIGNAL);
    if (n < 0) { *len = 0; return errno == EAGAIN || errno == EWOULDBLOCK ? errSSLWouldBlock : errSSLClosedAbort; }
    size_t want = *len; *len = n; return (size_t)n < want ? errSSLWouldBlock : noErr;
}
static __attribute__((used)) Result tls_create(void *self, void *ctx) {
    (void)ctx; if (!self || objmap_get(self)) return RES_FAIL;
    tls_conn *c = calloc(1, sizeof *c); if (!c) return RES_FAIL;
    c->fd = -1; c->mode = 1; c->tls = SSLCreateContext(NULL, kSSLClientSide, kSSLStreamType);
    if (!c->tls) { free(c); return RES_FAIL; }
    SSLSetProtocolVersionMin(c->tls, kTLSProtocol12);
    SSLSetIOFuncs(c->tls, tls_read_cb, tls_write_cb); SSLSetConnection(c->tls, c);
    objmap_put(self, c); return RES_OK;
}
static __attribute__((used)) Result tls_destroy(void *self) { tls_conn *c = objmap_del(self); if (c) { CFRelease(c->tls); free(c); } return RES_OK; }
static __attribute__((used)) Result tls_sock(void *self, int fd) { tls_conn *c = objmap_get(self); if (!c || !valid(fd)) return RES_FAIL; if (fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) < 0) return RES_FAIL; c->fd = fd; return RES_OK; }
static __attribute__((used)) Result tls_host(void *self, const char *h, unsigned n) {
    tls_conn *c = objmap_get(self); if (!c || !h || !n || n >= sizeof c->host) return RES_FAIL;
    n = (unsigned)strnlen(h, n); if (!n) return RES_FAIL;
    memcpy(c->host, h, n); c->host[n] = 0;
    return SSLSetPeerDomainName(c->tls, h, n) == noErr ? RES_OK : RES_FAIL;
}
static __attribute__((used)) Result tls_mode(void *self, int mode) { tls_conn *c = objmap_get(self); if (!c || (mode != 1 && mode != 2)) return RES_FAIL; c->mode = mode; return RES_OK; }
static __attribute__((used)) Result tls_option(void *self, int opt, int value) { (void)opt; (void)value; return objmap_get(self) ? RES_OK : RES_FAIL; }
static __attribute__((used)) Result tls_cache(void *self, int mode) { (void)mode; return objmap_get(self) ? RES_OK : RES_FAIL; }
static __attribute__((used)) Result tls_verify(void *self, int value) { (void)value; return objmap_get(self) ? RES_OK : RES_FAIL; } // verification always stays on
static Result ssl_result(OSStatus s) { return s == noErr || s == errSSLClosedGraceful ? RES_OK : s == errSSLWouldBlock ? 0x1987b : RES_FAIL; }
static __attribute__((used)) Result tls_handshake(void *self) {
    tls_conn *c = objmap_get(self); if (!c || c->fd < 0 || !c->host[0]) return RES_FAIL;
    net_block(1);
    OSStatus s;
    do { s = SSLHandshake(c->tls); if (s != errSSLWouldBlock || c->mode == 2) break;
        struct pollfd p = { c->fd, c->want, 0 }; if (poll(&p, 1, 30000) <= 0) break;
    } while (1);
    net_block(0); c->last = s;
    if (s != errSSLWouldBlock) LOG("OCW TLS handshake status=%d (verification enabled)", (int)s);
    return ssl_result(s);
}
static __attribute__((used)) Result tls_handshake_cert(void *self, unsigned *size, unsigned *count) {
    if (size) *size = 0; if (count) *count = 0; return tls_handshake(self);
}
static __attribute__((used)) Result tls_rw(void *self, void *buf, int *out, unsigned n, int write) {
    tls_conn *c = objmap_get(self); if (out) *out = 0; if (!c || !out || !buf) return RES_FAIL;
    size_t used = 0; OSStatus s;
    net_block(1);
    do { s = write ? SSLWrite(c->tls, buf, n, &used) : SSLRead(c->tls, buf, n, &used);
        if (used || s != errSSLWouldBlock || c->mode == 2) break;
        struct pollfd p = { c->fd, c->want, 0 }; if (poll(&p, 1, 30000) <= 0) break;
    } while (1);
    net_block(0); *out = (int)used; c->last = used ? noErr : s;
    return used ? RES_OK : ssl_result(s);
}
static __attribute__((used)) Result tls_read(void *s, void *b, int *out, unsigned n) { return tls_rw(s, b, out, n, 0); }
static __attribute__((used)) Result tls_write(void *s, const void *b, int *out, unsigned n) { return tls_rw(s, (void *)b, out, n, 1); }
static __attribute__((used)) int tls_read_int(void *s, void *b, unsigned n) { int out; return tls_read(s, b, &out, n) ? -1 : out; }
static __attribute__((used)) int tls_write_int(void *s, const void *b, unsigned n) { int out; return tls_write(s, b, &out, n) ? -1 : out; }
static __attribute__((used)) Result tls_pending(void *self, int *out) { tls_conn *c = objmap_get(self); size_t n = 0; if (!c || !out) return RES_FAIL; SSLGetBufferedReadSize(c->tls, &n); *out = (int)n; return RES_OK; }
static __attribute__((used)) Result tls_last(void *self, uint32_t *out) { tls_conn *c = objmap_get(self); if (!c || !out) return RES_FAIL; *out = ssl_result(c->last); return RES_OK; }
static __attribute__((used)) Result tls_cert_error(void *self, uint32_t *out) { tls_conn *c = objmap_get(self); if (!c || !out) return RES_FAIL; *out = (c->last == noErr || c->last == errSSLWouldBlock) ? 0 : RES_FAIL; return RES_OK; }

// Course World requires an existing Mii. Offer a deterministic local default
// to the OCW profile; the absent system editor cannot create a console Mii.
void dm_mii_default_profile(void *out);
static __attribute__((used)) int local_mii_count(void *self, int src) { (void)self; return (src & 3) ? 1 : 0; }
static __attribute__((used)) Result local_mii_get(void *self, int *out, void *buf, int n, int src) {
    (void)self; *out = buf && n > 0 && (src & 3) ? 1 : 0;
    if (*out) dm_mii_default_profile(buf); return RES_OK;
}
static __attribute__((used)) Result local_mii_get_element(void *self, int *out, void *buf, int n, int src) {
    Result r = local_mii_get(self, out, buf, n, src);
    if (*out) { uint32_t source = src & 1 ? 0 : 1; memcpy((uint8_t *)buf + 0x58, &source, 4); } return r;
}
static __attribute__((used)) Result local_mii_index(void *self, int *out, const void *info) {
    (void)self; uint8_t def[0x58]; dm_mii_default_profile(def);
    *out = info && !memcmp(info, def, 16) ? 0 : -1; return *out == 0 ? RES_OK : 0x87e;
}
static __attribute__((used)) Result local_mii_latest(void *self, void *info, int src) {
    (void)self; (void)src; uint8_t def[0x58]; dm_mii_default_profile(def);
    if (!info || memcmp(info, def, 16)) return 0x87e; memcpy(info, def, sizeof def); return RES_OK;
}
static __attribute__((used)) Result local_mii_append(int *index) { if (!index) return RES_FAIL; *index = 0; return RES_OK; }

// At main+0xaf564, snprintf has finished in the 1024-byte frame buffer at x24+0x500.
// x24 was established at +0xaf518 and is callee saved. Registers remain read-only.
static void header_ready(uint64_t *regs, int param) {
    (void)param;
    char *b = (char *)(uintptr_t)regs[24] + 0x500;
    const char *needle = "Sec-WebSocket-Protocol: "; char *line = strstr(b, needle);
    if (!line || strnlen(b, 1024) >= 1024) die("OCW HTTP header layout mismatch");
    char *value = line + strlen(needle), *end = strstr(value, "\r\n");
    if (!end || end - value > 100 || line - b > 800) die("OCW HTTP protocol mismatch");
    char protocol[101]; memcpy(protocol, value, end - value); protocol[end - value] = 0;
    size_t prefix = line - b;
    int n = snprintf(b + prefix, 1024 - prefix, "%s: %s\r\nMod-Version: 0.3\r\nGame-Version: 3.0.3\r\n\r\n", protocol, token);
    if (n < 0 || (size_t)n >= 1024 - prefix) die("OCW HTTP header overflow");
    LOG("OCW authenticated WebSocket header prepared (credential redacted)");
}
void dm_ocw_install(void) {
    if (strcmp(dm_main_build(), "c2dc405ac414c37c8b1c50219c7a0f0c")) return;
    @autoreleasepool {
        const char *save = getenv("DM_SAVE"); if (!save) return;
        NSString *p = [[[NSString stringWithUTF8String:save] stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"ocw-config.json"];
        NSData *data = [NSData dataWithContentsOfFile:p]; if (!data) return;
        if (data.length > 2048) die("OCW config too large");
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
        if (![json isKindOfClass:NSDictionary.class]) die("OCW config is not an object");
        id domain = json[@"domain"], secret = json[@"token"];
        if (![domain isKindOfClass:NSString.class] || ![domain isEqualToString:@"server.opencourse.world"] || ![secret isKindOfClass:NSString.class] || [secret lengthOfBytesUsingEncoding:NSUTF8StringEncoding] != 22) die("OCW config invalid");
        const char *t = [secret UTF8String]; for (int i = 0; i < 22; i++) if (t[i] < 33 || t[i] > 126) die("OCW token invalid");
        if (!gate_obs_present(OBS_OCW_HEADER)) die("OCW module has no HTTP header gate; rewrite first");
        module_t *m = NULL; for (int i = 0; i < g_nmod; i++) if (!strcmp(g_mod[i].name, "main")) m = &g_mod[i];
        const char *original = "g%08x-%%.s.n.srv.nintendo.net";
        if (!m || strcmp((char *)m->base + 0x22cc307, original)) die("OCW domain patch original mismatch");
        memset(m->base + 0x22cc307, 0, 29); memcpy(m->base + 0x22cc307, "server.opencourse.world", 23);
        memcpy(token, t, 22); gate_obs_set(OBS_OCW_HEADER, header_ready); enabled = 1;
        LOG("OCW 0.3 enabled for Mario Maker 2 3.0.3; credentials loaded from private app data");
    }
}

// Exact symbol lists keep overload ABI differences explicit. Existing offline entries
// still own every symbol not listed here, and all titles without an OCW configuration.
// A game network thread may have an 8 KB stack. Security and DNS execute on the
// per-thread host stack, exactly like other HLE_FORCE_BIG service implementations.
#ifndef OCW_TEST
#define ONLINE_BIG(fn) \
    extern const char fn##_bs[]; \
    __asm__(".text\n.p2align 2\n.globl _" #fn "_bs\n.private_extern _" #fn "_bs\n_" #fn "_bs:\n" \
            "    adrp x16, _" #fn "@PAGE\n    add x16, x16, _" #fn "@PAGEOFF\n    b _dm_bigstack_enter\n");
ONLINE_BIG(ip)
ONLINE_BIG(community_account_available)
ONLINE_BIG(net_accept)
ONLINE_BIG(net_bind)
ONLINE_BIG(net_close)
ONLINE_BIG(net_connect)
ONLINE_BIG(net_errno)
ONLINE_BIG(net_fcntl)
ONLINE_BIG(net_freeai)
ONLINE_BIG(net_gai)
ONLINE_BIG(net_getopt)
ONLINE_BIG(net_host)
ONLINE_BIG(net_listen)
ONLINE_BIG(net_name)
ONLINE_BIG(net_peer)
ONLINE_BIG(net_poll)
ONLINE_BIG(net_recv)
ONLINE_BIG(net_recvfrom)
ONLINE_BIG(net_send)
ONLINE_BIG(net_sendto)
ONLINE_BIG(net_seterrno)
ONLINE_BIG(net_setopt)
ONLINE_BIG(net_shutdown)
ONLINE_BIG(net_socket)
ONLINE_BIG(ok)
ONLINE_BIG(proxy)
ONLINE_BIG(free_communication)
ONLINE_BIG(resolve)
ONLINE_BIG(tls_cache)
ONLINE_BIG(tls_cert_error)
ONLINE_BIG(tls_create)
ONLINE_BIG(tls_ctx)
ONLINE_BIG(tls_ctx_destroy)
ONLINE_BIG(tls_destroy)
ONLINE_BIG(tls_handshake)
ONLINE_BIG(tls_handshake_cert)
ONLINE_BIG(tls_host)
ONLINE_BIG(tls_id)
ONLINE_BIG(tls_import)
ONLINE_BIG(tls_last)
ONLINE_BIG(tls_mode)
ONLINE_BIG(tls_option)
ONLINE_BIG(tls_pending)
ONLINE_BIG(tls_read)
ONLINE_BIG(tls_read_int)
ONLINE_BIG(tls_sock)
ONLINE_BIG(tls_verify)
ONLINE_BIG(tls_write)
ONLINE_BIG(tls_write_int)
ONLINE_BIG(network_available)
ONLINE_BIG(network_request_result)
ONLINE_BIG(network_submit_wait)
ONLINE_BIG(local_mii_count)
ONLINE_BIG(local_mii_get)
ONLINE_BIG(local_mii_get_element)
ONLINE_BIG(local_mii_index)
ONLINE_BIG(local_mii_latest)
ONLINE_BIG(local_mii_append)
#define MAP(name, fn) { name, (void *)fn##_bs }
#else
#define MAP(name, fn) { name, (void *)fn }
#endif
void *dm_ocw_resolve(const char *name) {
    if (!enabled) return NULL;
    static const struct { const char *name; void *fn; } map[] = {
        MAP("_ZN2nn7account32IsNetworkServiceAccountAvailableEPbRKNS0_10UserHandleE", community_account_available),
        MAP("_ZNK2nn3mii8Database8GetCountEi", local_mii_count),
        MAP("_ZN2nn3mii8Database3GetEPiPNS0_8CharInfoEii", local_mii_get),
        MAP("_ZN2nn3mii8Database3GetEPiPNS0_15CharInfoElementEii", local_mii_get_element),
        MAP("_ZNK2nn3mii8Database8GetIndexEPiRKNS0_8CharInfoE", local_mii_index),
        MAP("_ZNK2nn3mii8Database12UpdateLatestEPNS0_8CharInfoEi", local_mii_latest),
        MAP("_ZN2nn3mii9AppendMiiEPi", local_mii_append),

        MAP("_ZN2nn6socket6SocketENS0_6FamilyENS0_4TypeENS0_8ProtocolE", net_socket),
        MAP("_ZN2nn6socket4BindEiPKNS0_8SockAddrEj", net_bind),
        MAP("_ZN2nn6socket7ConnectEiPKNS0_8SockAddrEj", net_connect),
        MAP("_ZN2nn6socket6ListenEii", net_listen),
        MAP("_ZN2nn6socket6AcceptEiPNS0_8SockAddrEPj", net_accept),
        MAP("_ZN2nn6socket5CloseEi", net_close),
        MAP("_ZN2nn6socket11GetPeerNameEiPNS0_8SockAddrEPj", net_peer),
        MAP("_ZN2nn6socket11GetSockNameEiPNS0_8SockAddrEPj", net_name),
        MAP("_ZN2nn6socket10GetSockOptEiNS0_5LevelENS0_6OptionEPvPj", net_getopt),
        MAP("_ZN2nn6socket10SetSockOptEiNS0_5LevelENS0_6OptionEPKvj", net_setopt),
        MAP("_ZN2nn6socket5FcntlEiNS0_12FcntlCommandEz", net_fcntl),
        MAP("_ZN2nn6socket4PollEPNS0_6PollFdEmi", net_poll),
        MAP("_ZN2nn6socket4RecvEiPvmNS0_7MsgFlagE", net_recv),
        MAP("_ZN2nn6socket8RecvFromEiPvmNS0_7MsgFlagEPNS0_8SockAddrEPj", net_recvfrom),
        MAP("_ZN2nn6socket4SendEiPKvmNS0_7MsgFlagE", net_send),
        MAP("_ZN2nn6socket11GetAddrInfoEPKcS2_PKNS0_8AddrInfoEPPS3_", net_gai),
        MAP("_ZN2nn6socket12FreeAddrInfoEPNS0_8AddrInfoE", net_freeai),
        MAP("_ZN2nn6socket16GetHostEntByNameEPKcPKNS0_14ResolverOptionEm", net_host),
        MAP("_ZN2nn6socket12GetLastErrorEv", net_errno),
        MAP("nnsocketSocket", net_socket),
        MAP("nnsocketBind", net_bind),
        MAP("nnsocketConnect", net_connect),
        MAP("nnsocketClose", net_close),
        MAP("nnsocketGetPeerName", net_peer),
        MAP("nnsocketGetSockName", net_name),
        MAP("nnsocketGetSockOpt", net_getopt),
        MAP("nnsocketSetSockOpt", net_setopt),
        MAP("nnsocketFcntl", net_fcntl),
        MAP("nnsocketPoll", net_poll),
        MAP("nnsocketRecv", net_recv),
        MAP("nnsocketSend", net_send),
        MAP("nnsocketGetHostByNameWithOptions", net_host),
        MAP("nnsocketGetLastErrno", net_errno),
        MAP("nnsocketSetLastErrno", net_seterrno),
        MAP("_ZN2nn6socket12GetLastErrnoEv", net_errno),
        MAP("_ZN2nn6socket6SocketEiii", net_socket),
        MAP("_ZN2nn6socket8ShutdownEii", net_shutdown),
        MAP("_ZN2nn6socket4BindEiPK8sockaddrj", net_bind),
        MAP("_ZN2nn6socket4PollEP6pollfdmi", net_poll),
        MAP("_ZN2nn6socket6SendToEiPKvmiPK8sockaddrj", net_sendto),
        MAP("_ZN2nn6socket6SendToEiPKvmNS0_7MsgFlagEPKNS0_8SockAddrEj", net_sendto),
        MAP("_ZN2nn6socket8RecvFromEiPvmiP8sockaddrPj", net_recvfrom),
        MAP("_ZN2nn6socket11GetAddrInfoEPKcS2_PK8addrinfoPPS3_", net_gai),
        MAP("_ZN2nn6socket12FreeAddrInfoEP8addrinfo", net_freeai),
        MAP("_ZN2nn6socket7ConnectEiPK8sockaddrj", net_connect),
        MAP("_ZN2nn6socket6AcceptEiP8sockaddrPj", net_accept),
        MAP("_ZN2nn6socket11GetSockNameEiP8sockaddrPj", net_name),
        MAP("_ZN2nn6socket10GetSockOptEiiiPvPj", net_getopt),
        MAP("_ZN2nn6socket10SetSockOptEiiiPKvj", net_setopt),
        MAP("_ZN2nn6socket5FcntlEiiz", net_fcntl),
        MAP("_ZN2nn6socket4RecvEiPvmi", net_recv),
        MAP("_ZN2nn6socket4SendEiPKvmi", net_send),
        MAP("_ZN2nn4nifm18IsNetworkAvailableEv", network_available),
        MAP("_ZN2nn4nifm31HandleNetworkRequestErrorResultEv", network_request_result),
        MAP("_ZN2nn4nifm27SubmitNetworkRequestAndWaitEv", network_submit_wait),
        MAP("_ZN2nn4nifm26GetCurrentPrimaryIpAddressEP7in_addr", ip),
        MAP("_ZN2nn4nifm26GetCurrentPrimaryIpAddressEPNS_6socket6InAddrE", ip),
        MAP("_ZN2nn4nifm22GetCurrentProxySettingEPNS0_12ProxySettingE", proxy),
        MAP("_ZN2nn4pctl32CheckFreeCommunicationPermissionEb", free_communication),
        MAP("_ZN2nn3nsd9ResolveExEPNS0_4FqdnERKS1_", resolve),
        MAP("_ZN2nn3nsd7ResolveEPNS0_4FqdnERKS1_", resolve),
        MAP("_ZN2nn3ssl7Context6CreateENS1_10SslVersionE", tls_ctx),
        MAP("nnsslContextCreate", tls_ctx),
        MAP("_ZN2nn3ssl7Context7DestroyEv", tls_ctx_destroy),
        MAP("nnsslContextDestroy", tls_ctx_destroy),
        MAP("_ZN2nn3ssl7Context12GetContextIdEPm", tls_id),
        MAP("_ZN2nn3ssl10Connection15GetConnectionIdEPm", tls_id),
        MAP("_ZN2nn3ssl10Connection12GetContextIdEPm", tls_id),
        MAP("nnsslContextGetContextId", tls_id),
        MAP("nnsslConnectionGetConnectionId", tls_id),
        MAP("_ZN2nn3ssl7Context15ImportServerPkiEPmPKcjNS0_17CertificateFormatE", tls_import),
        MAP("_ZN2nn3ssl10Connection6CreateEPNS0_7ContextE", tls_create),
        MAP("nnsslConnectionCreate", tls_create),
        MAP("_ZN2nn3ssl10Connection7DestroyEv", tls_destroy),
        MAP("nnsslConnectionDestroy", tls_destroy),
        MAP("_ZN2nn3ssl10Connection19SetSocketDescriptorEi", tls_sock),
        MAP("nnsslConnectionSetSocketDescriptor", tls_sock),
        MAP("_ZN2nn3ssl10Connection11SetHostNameEPKcj", tls_host),
        MAP("nnsslConnectionSetHostName", tls_host),
        MAP("_ZN2nn3ssl10Connection9SetIoModeENS1_6IoModeE", tls_mode),
        MAP("nnsslConnectionSetIoMode", tls_mode),
        MAP("_ZN2nn3ssl10Connection19SetSessionCacheModeENS1_16SessionCacheModeE", tls_cache),
        MAP("nnsslConnectionSetSessionCacheMode", tls_cache),
        MAP("_ZN2nn3ssl10Connection9SetOptionENS1_10OptionTypeEb", tls_option),
        MAP("nnsslConnectionSetOption", tls_option),
        MAP("_ZN2nn3ssl10Connection15SetVerifyOptionENS1_12VerifyOptionE", tls_verify),
        MAP("nnsslConnectionSetVerifyOption", tls_verify),
        MAP("_ZN2nn3ssl10Connection11DoHandshakeEv", tls_handshake),
        MAP("nnsslConnectionDoHandshake", tls_handshake),
        MAP("_ZN2nn3ssl10Connection11DoHandshakeEPjS2_", tls_handshake_cert),
        MAP("nnsslConnectionDoHandshakeWithCertBuffer", tls_handshake_cert),
        MAP("_ZN2nn3ssl10Connection4ReadEPcPij", tls_read),
        MAP("nnsslConnectionRead", tls_read),
        MAP("_ZN2nn3ssl10Connection5WriteEPKcPij", tls_write),
        MAP("nnsslConnectionWrite", tls_write),
        MAP("_ZN2nn3ssl10Connection7PendingEPi", tls_pending),
        MAP("nnsslConnectionPending", tls_pending),
        MAP("_ZN2nn3ssl10Connection12GetLastErrorEPNS_6ResultE", tls_last),
        MAP("nnsslConnectionGetLastError", tls_last),
        MAP("_ZN2nn3ssl10Connection18GetVerifyCertErrorEPNS_6ResultE", tls_cert_error),
        MAP("nnsslConnectionGetVerifyCertError", tls_cert_error),
        MAP("_ZN2nn3ssl10Connection4ReadEPcj", tls_read_int),
        MAP("_ZN2nn3ssl10Connection5WriteEPKcj", tls_write_int),
    };
    for (size_t i = 0; i < sizeof map / sizeof *map; i++) if (!strcmp(name, map[i].name)) return map[i].fn;
    return NULL;
}
