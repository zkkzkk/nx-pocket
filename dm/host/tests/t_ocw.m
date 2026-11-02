// Standalone transport checks. Does not load or execute game code.
#define OCW_TEST 1
#import "../hle_ocw.m"
#include <assert.h>
#import "../hle_mii.c"
uint64_t dm_entropy64(void) { return 1; }
__thread _Atomic int dm_host_work;
void dm_thread_host_block(int entering) { (void)entering; }
void dm_applet_enter(const char *name) { (void)name; }
void dm_applet_leave(void) {}
module_t *g_mod; int g_nmod;
static void *keys[32], *values[32];
void *objmap_get(const void *p) { for (int i=0;i<32;i++) if(keys[i]==p) return values[i]; return NULL; }
void objmap_put(const void *p, void *v) { for(int i=0;i<32;i++) if(!keys[i] || keys[i]==p) { keys[i]=(void *)p; values[i]=v; return; } abort(); }
void *objmap_del(const void *p) { for(int i=0;i<32;i++) if(keys[i]==p) { void *v=values[i]; keys[i]=NULL; values[i]=NULL; return v; } return NULL; }
int gate_obs_present(int id) { (void)id; return 1; }
void gate_obs_set(int id, void (*fn)(uint64_t *, int)) { (void)id;(void)fn; }
int main(int argc, char **argv) {
    assert(!dm_ocw_resolve("nnsocketSocket")); enabled=1;
    assert(dm_ocw_resolve("nnsocketSocket")==net_socket);
    assert(!dm_ocw_resolve("unrelated"));
    // The game tests bit 0: network confirmation success is true, not Result(0).
    int (*confirm)(void) = dm_ocw_resolve("_ZN2nn4nifm31HandleNetworkRequestErrorResultEv");
    assert(confirm && (confirm() & 1) == 1);
    assert(((int (*)(void))dm_ocw_resolve("_ZN2nn4nifm18IsNetworkAvailableEv"))() == 1);
    uint8_t available = 0;
    Result (*account_available)(uint8_t *, const void *) = dm_ocw_resolve("_ZN2nn7account32IsNetworkServiceAccountAvailableEPbRKNS0_10UserHandleE");
    assert(account_available && account_available(&available, NULL) == 0 && available == 1);
    // cCheckParentalControl tests bit 0; false returns the login sequence to cIdle.
    int (*permitted)(unsigned) = dm_ocw_resolve("_ZN2nn4pctl32CheckFreeCommunicationPermissionEb");
    assert(permitted && (permitted(0) & 1) == 1);
    // The caller ignores ResolveEx's Result, so the output must be defined either way.
    Result (*resolve_ex)(char *, const char *) = dm_ocw_resolve("_ZN2nn3nsd9ResolveExEPNS0_4FqdnERKS1_");
    char fqdn_in[256] = "server.opencourse.world", fqdn_out[256]; memset(fqdn_out, 'x', sizeof fqdn_out);
    assert(resolve_ex && resolve_ex(fqdn_out, fqdn_in) == 0 && !strcmp(fqdn_out, "server.opencourse.world"));
    strcpy(fqdn_in, "g12345678-%.s.n.srv.nintendo.net"); memset(fqdn_out, 'x', sizeof fqdn_out);
    assert(resolve_ex(fqdn_out, fqdn_in) != 0 && fqdn_out[0] == 0);
    assert(tls_ctx(NULL, 1) == 0); // nn::Result success is still zero for SSL creation.
    assert(net_send(1234,"x",1,0)==-1 && net_errno()==EBADF);
    _Static_assert(sizeof(struct addrinfo)==48,"FreeBSD/Darwin addrinfo size");
    _Static_assert(offsetof(struct addrinfo, ai_addr)==32,"guest ai_addr offset");
    unsigned char frame[4096]={0}; uint64_t regs[31]={0}; regs[24]=(uintptr_t)frame;
    char *b=(char *)frame+0x500;
    strcpy(b,"GET /nex HTTP/1.1\r\nHost: server.opencourse.world\r\nUpgrade: websocket\r\nConnection: upgrade\r\nSec-WebSocket-Key: example\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: nex\r\n\r\n");
    memcpy(token,"0123456789012345678901",23); uint64_t before[31];memcpy(before,regs,sizeof regs);
    header_ready(regs, 0); assert(!memcmp(before,regs,sizeof regs));
    assert(strstr(b,"nex: 0123456789012345678901\r\nMod-Version: 0.3\r\nGame-Version: 3.0.3\r\n\r\n"));
    assert(!strstr(b,"Sec-WebSocket-Protocol:"));
    uint8_t mii[0x58]; int mi, count; assert(local_mii_count(NULL,1)==1);
    assert(!local_mii_get(NULL,&count,mii,1,1) && count==1);
    assert(!local_mii_index(NULL,&mi,mii) && mi==0); assert(!local_mii_latest(NULL,mii,1));
    int server=net_socket(2,SOCK_STREAM,0); assert(server>=0);
    struct sockaddr_in a={.sin_len=sizeof a,.sin_family=AF_INET,.sin_addr.s_addr=htonl(INADDR_LOOPBACK)};
    assert(!net_bind(server,&a,sizeof a));unsigned al=sizeof a;assert(!net_name(server,&a,&al));assert(!net_listen(server,1));
    int client=net_socket(2,SOCK_STREAM,0);assert(!net_connect(client,&a,sizeof a));int peer=net_accept(server,NULL,NULL);assert(peer>=0);
    assert(net_send(client,"hello",5,0)==5);struct pollfd p={peer,POLLIN,0};assert(net_poll(&p,1,1000)==1);
    char buf[2048];assert(net_recv(peer,buf,5,0)==5 && !memcmp(buf,"hello",5));
    assert(!net_fcntl(peer,F_SETFL,O_NONBLOCK));assert(net_recv(peer,buf,1,0)==-1 && net_errno()==EAGAIN);
    assert(!net_close(peer));assert(net_close(peer)==-1);assert(!net_close(client));assert(!net_close(server));
    struct addrinfo *ai=NULL; assert(!net_gai("localhost","443",NULL,&ai) && ai);net_freeai(ai);
    if(argc>1 && !strcmp(argv[1],"--live")) {
        struct addrinfo hint={.ai_family=AF_INET,.ai_socktype=SOCK_STREAM};
        assert(!net_gai("server.opencourse.world","443",&hint,&ai));
        int s=net_socket(ai->ai_family,ai->ai_socktype,ai->ai_protocol); assert(s>=0);assert(!net_connect(s,ai->ai_addr,ai->ai_addrlen));net_freeai(ai);
        int key; assert(!tls_create(&key,NULL));assert(!tls_sock(&key,s));assert(!tls_host(&key,"server.opencourse.world",(unsigned)strlen("server.opencourse.world")));assert(!tls_handshake(&key));
        const char *request="GET / HTTP/1.1\r\nHost: server.opencourse.world\r\nConnection: close\r\n\r\n";int n;
        assert(!tls_write(&key,request,&n,(unsigned)strlen(request)) && n==(int)strlen(request));
        assert(!tls_read(&key,buf,&n,sizeof buf-1) && n>0);buf[n]=0;assert(!strncmp(buf,"HTTP/1.1 ",9));
        printf("Live TLS/HTTP passed (status %.3s); no account credential sent\n",buf+9);
        assert(!tls_destroy(&key));assert(!net_close(s));
    }
    puts("OCW transport checks passed");return 0;
}
