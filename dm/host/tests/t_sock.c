// Local network play's sockets (hle_sock.c) on loopback, DM_NET=lan on lo0: UDP and TCP through the guest's descriptors, the values of Horizon's bsd ABI (SOCK_NONBLOCK in
// the type, a 16-byte timeval, fcntl's 0x800; Linux's errors: EAGAIN 11, EBADF 9, ENETUNREACH 101), Poll / Select, and which destinations are allowed
#include "../hle_sock.c"
#include <assert.h>

int dm_detclock_enabled(void) { return 0; }
void dm_guest_blocking(int on) { (void)on; }
static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (errno %d)\n", msg, dm_sock_errno()); } } while (0)
static uint32_t ip4(int a, int b, int c, int d) { return (uint32_t)a << 24 | (uint32_t)b << 16 | (uint32_t)c << 8 | (uint32_t)d; }
// The guest's sockaddr_in: {u8 len, u8 family, u16 port (network order), u32 address (network order), zero[8]}
typedef struct { uint8_t len, family; uint16_t port; uint32_t addr; uint8_t zero[8]; } gsa;
static gsa lo(uint16_t port) { gsa a = {16, 2, htons(port), htonl(0x7f000001), {0}}; return a; }

int main(void) {
    setenv("DM_NET", "lan", 1); setenv("DM_NET_IF", "lo0", 1); unsetenv("DM_NET_PEERS"); unsetenv("DM_NET_UNICAST");
    CHECK(dm_net_on(), "DM_NET=lan turns local network play on");
    uint32_t ip, mask; CHECK(dm_net_local(&ip, &mask) && ip == 0x7f000001 && mask == 0xff000000, "DM_NET_IF=lo0 plays on 127.0.0.1/8");

    // where a guest may send
    CHECK(dm_net_allowed(ip4(192, 168, 1, 20)) && dm_net_allowed(ip4(10, 0, 0, 2)) && dm_net_allowed(ip4(172, 20, 1, 1)), "private ranges allowed");
    CHECK(dm_net_allowed(ip4(100, 101, 5, 6)) && dm_net_allowed(ip4(169, 254, 3, 3)) && dm_net_allowed(0xffffffff), "100.64/10, link-local and the limited broadcast allowed");
    CHECK(!dm_net_allowed(ip4(8, 8, 8, 8)) && !dm_net_allowed(ip4(172, 32, 0, 1)) && !dm_net_allowed(ip4(100, 128, 0, 1)), "the Internet refused");
    uint32_t room[2] = {ip4(8, 8, 4, 4), ip4(192, 168, 1, 9)}; dm_net_set_room(room, 2);
    CHECK(dm_net_allowed(ip4(8, 8, 4, 4)), "a room node is allowed wherever it is");
    dm_net_set_room(NULL, 0);
    CHECK(is_broadcast(0xffffffff) && is_broadcast(ip4(127, 255, 255, 255)) && !is_broadcast(ip4(127, 0, 0, 9)), "broadcast addresses of lo0's subnet");

    // UDP: bind to an ephemeral port, find it, send to it, read it back with the sender's address
    int u = dm_sock_socket(2, 2, 0), v = dm_sock_socket(2, 2 | 0x20000000, 0);
    CHECK(u >= 3 && v >= 3 && u != v, "two UDP descriptors from 3 up");
    gsa a = lo(0); CHECK(dm_sock_bind(u, &a, 16) == 0, "bind 127.0.0.1:0");
    gsa got; unsigned gl = sizeof got; CHECK(dm_sock_getsockname(u, &got, &gl) == 0 && gl == 16 && got.len == 16 && got.family == 2 && got.port, "getsockname gives the guest's sockaddr");
    char buf[64];
    CHECK(dm_sock_recv(v, buf, sizeof buf, 0) == -1 && dm_sock_errno() == 11, "SOCK_NONBLOCK in the type: nothing to read is Linux's EAGAIN (11)");
    CHECK(dm_sock_sendto(v, "ping", 4, 0x20000, &got, 16) == 4, "sendto with MSG_NOSIGNAL");
    struct { int32_t fd; int16_t events, revents; } pf[2] = {{u, 1, 0}, {999, 1, 0}};
    CHECK(dm_sock_poll(pf, 1, 1000) == 1 && pf[0].revents & 1, "poll: readable");
    CHECK(dm_sock_poll(pf, 2, 1000) == 2 && pf[0].revents & 1 && pf[1].revents == 0x20, "poll: POLLNVAL for an unknown descriptor, at once");
    gsa from; unsigned fl = sizeof from;
    CHECK(dm_sock_recvfrom(u, buf, sizeof buf, 0, &from, &fl) == 4 && !memcmp(buf, "ping", 4) && from.addr == htonl(0x7f000001) && fl == 16, "recvfrom with the sender");
    int64_t tv[2] = {1, 500000}, tv2[2] = {0, 0}; unsigned tl = 16;
    CHECK(dm_sock_setsockopt(u, 0xffff, 0x1006, tv, 16) == 0 && dm_sock_getsockopt(u, 0xffff, 0x1006, tv2, &tl) == 0 && tv2[0] == 1 && tv2[1] == 500000 && tl == 16, "SO_RCVTIMEO's 16-byte timeval both ways");
    CHECK(dm_sock_setsockopt(u, 0xffff, 0x1234, tv, 4) == 0, "an option the host lacks is accepted");
    CHECK(dm_sock_fcntl(v, 3, 0) & 0x800, "F_GETFL shows Linux's O_NONBLOCK");
    CHECK(dm_sock_fcntl(v, 4, 0) == 0 && !(dm_sock_fcntl(v, 3, 0) & 0x800), "F_SETFL clears it");
    CHECK(dm_sock_fcntl(v, 4, 0x800) == 0 && dm_sock_fcntl(v, 3, 0) & 0x800 && dm_sock_recv(v, buf, sizeof buf, 0) == -1 && dm_sock_errno() == 11, "F_SETFL 0x800 sets it again");
    gsa far = {16, 2, htons(53), htonl(ip4(8, 8, 8, 8)), {0}};
    CHECK(dm_sock_sendto(u, "x", 1, 0, &far, 16) == -1 && dm_sock_errno() == 101, "sendto the Internet: ENETUNREACH (101)");

    // TCP: listen, connect, accept, both ways, select
    int l = dm_sock_socket(2, 1, 0), c = dm_sock_socket(2, 1, 0);
    a = lo(0); CHECK(dm_sock_bind(l, &a, 16) == 0 && dm_sock_listen(l, 4) == 0, "listen");
    gl = sizeof got; dm_sock_getsockname(l, &got, &gl);
    CHECK(dm_sock_connect(c, &got, 16) == 0, "connect");
    gsa peer; unsigned pl = sizeof peer;
    int s = dm_sock_accept(l, &peer, &pl);
    CHECK(s >= 3 && peer.addr == htonl(0x7f000001), "accept with the peer's address");
    CHECK(dm_sock_send(c, "hello", 5, 0) == 5, "send");
    uint64_t rd[16] = {0}; rd[s >> 6] |= 1ull << (s & 63);
    int64_t wait[2] = {1, 0};
    CHECK(dm_sock_select(s + 1, rd, NULL, NULL, wait) == 1 && rd[s >> 6] >> (s & 63) & 1, "select: readable");
    CHECK(dm_sock_recv(s, buf, sizeof buf, 0) == 5 && !memcmp(buf, "hello", 5), "recv");
    CHECK(dm_sock_getpeername(c, &peer, &pl) == 0 && peer.port == got.port, "getpeername");
    gsa far2 = {16, 2, htons(80), htonl(ip4(1, 1, 1, 1)), {0}};
    int d = dm_sock_socket(2, 1, 0);
    CHECK(dm_sock_connect(d, &far2, 16) == -1 && dm_sock_errno() == 101, "connect to the Internet: ENETUNREACH (101)");
    CHECK(dm_sock_socket(28, 1, 0) == -1 && dm_sock_errno() == 97, "IPv6: EAFNOSUPPORT (97)");
    int fds[] = {u, v, l, c, s, d};
    for (int i = 0; i < 6; i++) CHECK(dm_sock_close(fds[i]) == 0, "close");
    CHECK(dm_sock_close(u) == -1 && dm_sock_errno() == 9 && dm_sock_send(u, "x", 1, 0) == -1 && dm_sock_errno() == 9, "a closed descriptor: EBADF (9)");

    printf("t_sock: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
