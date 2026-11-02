// Local wireless over the LAN (hle_ldn.c on hle_sock.c), through the real hooks: a host and a station, each its own process on 127.0.0.1 with its own port (DM_LDN_PORT).
// The station finds the room by its peer address alone, as an iPhone must (DM_NET_UNICAST=1, no broadcast), joins, sees the host's advertise data change, and leaves; the
// host sees it come and go. Also the packet format as ldn_mitm writes it, and the offline answers with DM_NET unset
#include "../hle_sock.c"
#include "../hle_ldn.c"
#include <signal.h>
#include <sys/wait.h>
#include <time.h>

int dm_detclock_enabled(void) { return 0; }
void dm_guest_blocking(int on) { (void)on; }
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
void dm_guest_sleep_ns(int64_t ns) { struct timespec t = {(time_t)(ns / 1000000000), (long)(ns % 1000000000)}; nanosleep(&t, NULL); }
static int signals;
void hle_signal_system_event(void *e) { (void)e; signals++; }
void hle_bind_system_event(void *e, int autoclear) { (void)e; (void)autoclear; }
void hle_rebind_system_event(void *e, int autoclear) { (void)e; (void)autoclear; }
static int checks, fails;
static const char *who = "t_ldn";
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL (%s): %s\n", who, msg); } } while (0)
enum { HOST_PORT = 21452, STA_PORT = 21453 };
static const uint64_t GAME = 0x01006a800016e000ull;
static uint8_t ev[0x40];
static void sleep_ms(int ms) { dm_guest_sleep_ns((int64_t)ms * 1000000); }
static int node_count(void) { static ldn_netinfo ni; return h_ldn_NetInfo(&ni) ? -1 : ni.ldn.node_count; }
static int adv_is(const char *s) { static ldn_netinfo ni; return !h_ldn_NetInfo(&ni) && ni.ldn.adv_size == strlen(s) && !memcmp(ni.ldn.adv, s, strlen(s)); }
static int wait_for(int (*f)(void *), void *arg, int ms) { for (int t = 0; t < ms; t += 20) { if (f(arg)) return 1; sleep_ms(20); } return 0; }
static int nodes_are(void *n) { return node_count() == *(int *)n; }
static int adv_matches(void *s) { return adv_is(s); }
static int state_is(void *s) { return h_ldn_State() == *(int *)s; }

static void net_env(int port, const char *peers) {
    setenv("DM_NET", "lan", 1); setenv("DM_NET_IF", "lo0", 1); setenv("DM_NET_UNICAST", "1", 1); setenv("DM_LDN_SCAN_MS", "300", 1);
    char p[16]; snprintf(p, sizeof p, "%d", port); setenv("DM_LDN_PORT", p, 1);
    if (peers) setenv("DM_NET_PEERS", peers, 1); else unsetenv("DM_NET_PEERS");
}
static int host(void) {
    who = "host"; net_env(HOST_PORT, NULL);
    h_ldn_Attach(ev);
    CHECK(h_ldn_Init() == RES_OK && h_ldn_State() == ST_INIT, "initialize");
    CHECK(h_ldn_OpenAp() == RES_OK && h_ldn_State() == ST_AP, "open access point");
    CHECK(h_ldn_Adv("hello", 5) == RES_OK, "advertise data before the room");
    ldn_netcfg nc = {.intent = {.local_comm_id = GAME, .scene_id = 3}, .channel = 0, .node_count_max = 4, .local_comm_version = 7};
    ldn_seccfg sc = {.security_mode = 1}; ldn_usercfg uc = {.user = "HostPlayer"};
    CHECK(h_ldn_Create(&nc, &sc, &uc) == RES_OK && h_ldn_State() == ST_AP_UP, "create the room");
    int one = 1, two = 2;
    CHECK(nodes_are(&one), "a new room has one node");
    CHECK(wait_for(nodes_are, &two, 8000), "the station joins");
    static ldn_netinfo ni; h_ldn_NetInfo(&ni);
    CHECK(!strcmp(ni.ldn.nodes[1].user, "StationPlayer") && ni.ldn.nodes[1].node_id == 1 && ni.ldn.nodes[1].ip == 0x7f000001 && ni.ldn.nodes[1].local_comm_version == 7, "node 1 is the station");
    sleep_ms(300);
    CHECK(h_ldn_Adv("round2", 6) == RES_OK, "advertise data changed in the room");
    CHECK(wait_for(nodes_are, &one, 8000), "the station leaves");
    CHECK(signals >= 3, "the state event was signalled for the changes");
    CHECK(h_ldn_Destroy() == RES_OK && h_ldn_State() == ST_AP, "destroy the room");
    CHECK(h_ldn_CloseAp() == RES_OK && h_ldn_State() == ST_INIT, "close access point");
    h_ldn_Fini();
    CHECK(h_ldn_State() == ST_NONE, "finalized");
    return fails;
}
static int station(void) {
    who = "station"; char peers[32]; snprintf(peers, sizeof peers, "127.0.0.1:%d", HOST_PORT); net_env(STA_PORT, peers);
    h_ldn_Attach(ev);
    CHECK(h_ldn_Init() == RES_OK && h_ldn_OpenSta() == RES_OK && h_ldn_State() == ST_STA, "initialize and open station");
    static ldn_netinfo found[4]; int n = 0;
    ldn_filter f; memset(&f, 0, sizeof f); f.id.intent.local_comm_id = GAME; f.flag = F_LOCAL_COMM_ID;
    for (int i = 0; i < 20 && !n; i++) h_ldn_Scan(found, &n, 4, &f, 0);
    CHECK(n == 1, "the room is found by the peer address, without a broadcast");
    CHECK(n == 1 && found[0].ldn.adv_size == 5 && !memcmp(found[0].ldn.adv, "hello", 5) && found[0].id.intent.scene_id == 3, "the scan answer carries the room");
    f.id.intent.local_comm_id = GAME + 1; int m = 9; h_ldn_Scan(found + 1, &m, 3, &f, 0);
    CHECK(m == 0, "another game's filter finds nothing");
    ldn_seccfg sc = {.security_mode = 1}; ldn_usercfg uc = {.user = "StationPlayer"};
    CHECK(n == 1 && h_ldn_Connect(&found[0], &sc, &uc, 7, 0) == RES_OK && h_ldn_State() == ST_STA_UP, "join the room");
    CHECK(node_count() == 2, "the room has two nodes");
    uint32_t ip, mask; CHECK(h_ldn_Ip(&ip, &mask) == RES_OK && ip == 0x7f000001 && mask == 0xff000000, "our address in host byte order");
    ldn_secparam sp; CHECK(h_ldn_SecPrm(&sp) == RES_OK && !memcmp(&sp.session, &found[0].id.session, sizeof sp.session), "the room's session");
    CHECK(wait_for(adv_matches, "round2", 5000), "the host's new advertise data reaches the station");
    CHECK(h_ldn_Disc() == RES_OK && h_ldn_State() == ST_STA && h_ldn_DiscReason() == DR_USER, "leave the room");
    h_ldn_CloseSta(); h_ldn_Fini();
    return fails;
}
static int offline(void) {
    who = "offline"; unsetenv("DM_NET");
    int n = 5; static ldn_netinfo out[1];
    CHECK(h_ldn_Init() == RES_FAIL && h_ldn_State() == 0, "offline: initialization fails, state none");
    CHECK(h_ldn_Scan(out, &n, 1, NULL, 0) == RES_FAIL && n == 0, "offline: a scan finds nothing");
    CHECK(h_ldn_OpenAp() == RES_FAIL && h_ldn_CtrlRestrict(1) == RES_FAIL, "offline: nothing else works");
    return fails;
}
static int run(int (*f)(void)) {
    pid_t p = fork();
    if (!p) { alarm(30); int r = f(); fprintf(stderr, "t_ldn %s: %d checks, %d failed\n", who, checks, fails); _exit(r ? 1 : 0); }
    return p;
}
static int reap(pid_t p) { int st; waitpid(p, &st, 0); return WIFEXITED(st) && WEXITSTATUS(st) == 0; }

int main(void) {
    // the wire: a Scan's header as ldn_mitm sends it, and the zero-run compression both ways
    uint8_t buf[PK_MAX]; static const uint8_t scan[12] = {0x00, 0x14, 0x45, 0x11, 0, 0, 0, 0, 0, 0, 0, 0};
    CHECK(pk_build(PK_SCAN, NULL, 0, buf) == 12 && !memcmp(buf, scan, 12), "a Scan is the bare 12-byte header");
    uint8_t raw[8] = {1, 0, 0, 0, 2, 0, 0, 0}, c[16], d[16];
    int cn = pk_compress(raw, 8, c, 16);
    CHECK(cn == 6 && !memcmp(c, (uint8_t[]){1, 0, 2, 2, 0, 2}, 6), "zeros as {0, further zeros}");
    uint8_t c2[] = {1, 0, 2, 2, 0, 2};
    CHECK(pk_decompress(c2, 6, d, 16) == 8 && !memcmp(d, raw, 8), "decompressed back");
    static ldn_netinfo ni; ni.ldn.node_count = 1; ni.common.channel = 6; memcpy(ni.ldn.adv, "abc", 3);
    int len = pk_build(PK_SYNC, &ni, sizeof ni, buf); pk_head h; memcpy(&h, buf, sizeof h);
    CHECK(h.compressed == 1 && h.raw_len == sizeof ni && h.len + 12 == len && len < 100, "a mostly empty NetworkInfo is sent compressed");
    int type, on; static uint8_t body[PK_MAX];
    CHECK(pk_parse(buf, len, &type, body, &on) == len && type == PK_SYNC && on == sizeof ni && !memcmp(body, &ni, sizeof ni), "and parsed back whole");
    CHECK(pk_parse(buf, len - 1, &type, body, &on) == 0, "a partial packet waits for the rest");
    buf[0] ^= 1; CHECK(pk_parse(buf, len, &type, body, &on) == -1, "a wrong magic is rejected");
    printf("t_ldn wire: %d checks, %d failed\n", checks, fails);

    int ok = reap(run(offline));
    pid_t hp = run(host); sleep_ms(300);
    pid_t sp = run(station);
    ok &= reap(sp); ok &= reap(hp);
    printf("t_ldn: host / station / offline %s\n", ok ? "passed" : "FAILED");
    return fails || !ok;
}
