// See PackSign.h. The blob layouts are Apple's (xnu's cs_blobs.h, codesign's output); the CMS is built by hand as DER (Security.framework has no CMS encoder on iOS),
// as zsign builds it with OpenSSL: SignedData over the CodeDirectory with the signed attributes contentType, signingTime, messageDigest and Apple's two CDHash attributes.
#include "PackSign.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <fts.h>
#include <mach-o/loader.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define CSMAGIC_REQUIREMENTS 0xfade0c01
#define CSMAGIC_CODEDIRECTORY 0xfade0c02
#define CSMAGIC_EMBEDDED_SIGNATURE 0xfade0cc0
#define CSMAGIC_BLOBWRAPPER 0xfade0b01
#define CSSLOT_CODEDIRECTORY 0
#define CSSLOT_INFOSLOT 1
#define CSSLOT_REQUIREMENTS 2
#define CSSLOT_RESOURCEDIR 3
#define CSSLOT_SIGNATURESLOT 0x10000
#define CD_HEADER 88          // CodeDirectory version 0x20400 (execSeg fields)
#define CD_VERSION 0x20400
#define PAGE_BITS 14   // 16 KiB pages, as codesign signs for arm64
#define PAGE (1 << PAGE_BITS)
#define CMS_RESERVE 16384     // room kept for the CMS blob (three certificates and the signature are about 5 KiB)

static int fail(char *err, size_t n, const char *fmt, ...) {
    va_list a; va_start(a, fmt); vsnprintf(err, n, fmt, a); va_end(a); return -1;
}

// ---- growing byte buffers and DER ----
typedef struct { uint8_t *p; size_t n, cap; } buf;
static void put(buf *b, const void *d, size_t n) {
    if (b->n + n > b->cap) { b->cap = (b->n + n) * 2 + 64; b->p = realloc(b->p, b->cap); }
    memcpy(b->p + b->n, d, n); b->n += n;
}
static void put32be(buf *b, uint32_t v) { uint8_t x[4] = {v >> 24, v >> 16, v >> 8, v}; put(b, x, 4); }
static void put64be(buf *b, uint64_t v) { put32be(b, (uint32_t)(v >> 32)); put32be(b, (uint32_t)v); }
static void der(buf *out, uint8_t tag, const void *body, size_t n) {   // one TLV
    uint8_t h[6]; size_t k = 0; h[k++] = tag;
    if (n < 0x80) h[k++] = (uint8_t)n;
    else if (n < 0x100) { h[k++] = 0x81; h[k++] = (uint8_t)n; }
    else if (n < 0x10000) { h[k++] = 0x82; h[k++] = (uint8_t)(n >> 8); h[k++] = (uint8_t)n; }
    else { h[k++] = 0x83; h[k++] = (uint8_t)(n >> 16); h[k++] = (uint8_t)(n >> 8); h[k++] = (uint8_t)n; }
    put(out, h, k); put(out, body, n);
}
static void derb(buf *out, uint8_t tag, buf *body) { der(out, tag, body->p, body->n); free(body->p); *body = (buf){0}; }
// OIDs as their DER contents
static const uint8_t K_DATA[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01};
static const uint8_t K_SIGNED_DATA[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02};
static const uint8_t K_SHA256[] = {0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01};
static const uint8_t K_RSA[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01};
static const uint8_t K_CONTENT_TYPE[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x03};
static const uint8_t K_MESSAGE_DIGEST[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x04};
static const uint8_t K_SIGNING_TIME[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x05};
static const uint8_t K_CDHASHES[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x09, 0x01};    // 1.2.840.113635.100.9.1: a plist of truncated CDHashes
static const uint8_t K_CDHASHES2[] = {0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x09, 0x02};   // 1.2.840.113635.100.9.2: each CDHash with its algorithm

// A DER element of a certificate: tag, where its contents start, how long they are; 0 when malformed
static int tlv(const uint8_t *p, size_t n, size_t *hdr, size_t *len) {
    if (n < 2) return 0;
    size_t l = p[1], h = 2;
    if (l & 0x80) { int k = l & 0x7f; if (k < 1 || k > 3 || n < 2 + (size_t)k) return 0; l = 0; for (int i = 0; i < k; i++) l = l << 8 | p[2 + i]; h += k; }
    if (h + l > n) return 0;
    *hdr = h; *len = l; return 1;
}
// The certificate's issuer Name and serial number INTEGER, each as its whole DER element (IssuerAndSerialNumber)
static int issuer_serial(CFDataRef cert, const uint8_t **iss, size_t *issn, const uint8_t **ser, size_t *sern) {
    const uint8_t *p = CFDataGetBytePtr(cert); size_t n = (size_t)CFDataGetLength(cert), h, l;
    if (!tlv(p, n, &h, &l) || p[0] != 0x30) return 0;
    p += h; n = l;                                           // Certificate → tbsCertificate
    if (!tlv(p, n, &h, &l) || p[0] != 0x30) return 0;
    p += h; n = l;
    if (p[0] == 0xa0) { if (!tlv(p, n, &h, &l)) return 0; p += h + l; n -= h + l; }   // [0] version
    if (!tlv(p, n, &h, &l) || p[0] != 0x02) return 0;
    *ser = p; *sern = h + l; p += h + l; n -= h + l;          // serialNumber
    if (!tlv(p, n, &h, &l)) return 0;
    p += h + l; n -= h + l;                                  // signature algorithm
    if (!tlv(p, n, &h, &l) || p[0] != 0x30) return 0;
    *iss = p; *issn = h + l; return 1;
}

static void sha256(const void *d, size_t n, uint8_t out[32]) { CC_SHA256(d, (CC_LONG)n, out); }
static int file_hash(const char *path, uint8_t sha1[20], uint8_t s256[32]) {
    int fd = open(path, O_RDONLY); if (fd < 0) return 0;
    struct stat st; fstat(fd, &st);
    CC_SHA1_CTX c1; CC_SHA256_CTX c2; CC_SHA1_Init(&c1); CC_SHA256_Init(&c2);
    uint8_t b[65536]; ssize_t r;
    while ((r = read(fd, b, sizeof b)) > 0) { CC_SHA1_Update(&c1, b, (CC_LONG)r); CC_SHA256_Update(&c2, b, (CC_LONG)r); }
    close(fd);
    if (sha1) CC_SHA1_Final(sha1, &c1); else { uint8_t x[20]; CC_SHA1_Final(x, &c1); }
    CC_SHA256_Final(s256, &c2); return r == 0;
}

// ---- the resource seal: _CodeSignature/CodeResources, as codesign writes it for a framework (files: SHA-1, files2: SHA-256 without Info.plist, the standard rules) ----
static CFDictionaryRef rule(int weight, int optional, int omit) {
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    if (weight) { CFNumberRef w = CFNumberCreate(NULL, kCFNumberIntType, &weight); CFDictionarySetValue(d, CFSTR("weight"), w); CFRelease(w); }
    if (optional) CFDictionarySetValue(d, CFSTR("optional"), kCFBooleanTrue);
    if (omit) CFDictionarySetValue(d, CFSTR("omit"), kCFBooleanTrue);
    return d;
}
static void set_rule(CFMutableDictionaryRef d, CFStringRef k, CFDictionaryRef r) { CFDictionarySetValue(d, k, r); CFRelease(r); }
static int write_resources(const char *fw, const char *exe, char *err, size_t errlen) {
    CFMutableDictionaryRef files = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef files2 = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    char *roots[] = {(char *)fw, NULL};
    FTS *f = fts_open(roots, FTS_PHYSICAL | FTS_NOCHDIR, NULL);
    if (!f) return fail(err, errlen, "cannot list %s", fw);
    size_t base = strlen(fw) + 1;
    for (FTSENT *e; (e = fts_read(f));) {
        if (e->fts_info != FTS_F || e->fts_pathlen <= base) continue;
        const char *rel = e->fts_path + base;
        if (!strcmp(rel, exe) || !strncmp(rel, "_CodeSignature/", 15) || !strcmp(rel, ".DS_Store")) continue;
        uint8_t h1[20], h2[32];
        if (!file_hash(e->fts_path, h1, h2)) { fts_close(f); return fail(err, errlen, "cannot read %s", e->fts_path); }
        CFStringRef k = CFStringCreateWithCString(NULL, rel, kCFStringEncodingUTF8);
        CFDataRef d1 = CFDataCreate(NULL, h1, 20), d2 = CFDataCreate(NULL, h2, 32);
        CFDictionarySetValue(files, k, d1);
        if (strcmp(rel, "Info.plist")) {   // Info.plist is the CodeDirectory's own slot; files2 leaves it out
            CFMutableDictionaryRef e2 = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
            CFDictionarySetValue(e2, CFSTR("hash2"), d2); CFDictionarySetValue(files2, k, e2); CFRelease(e2);
        }
        CFRelease(k); CFRelease(d1); CFRelease(d2);
    }
    fts_close(f);
    CFMutableDictionaryRef rules = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFMutableDictionaryRef rules2 = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(rules, CFSTR("^.*"), kCFBooleanTrue);
    set_rule(rules, CFSTR("^.*\\.lproj/"), rule(1000, 1, 0));
    set_rule(rules, CFSTR("^.*\\.lproj/locversion.plist$"), rule(1100, 0, 1));
    set_rule(rules, CFSTR("^Base\\.lproj/"), rule(1010, 0, 0));
    CFDictionarySetValue(rules, CFSTR("^version.plist$"), kCFBooleanTrue);
    set_rule(rules2, CFSTR(".*\\.dSYM($|/)"), rule(11, 0, 0));
    CFDictionarySetValue(rules2, CFSTR("^.*"), kCFBooleanTrue);
    set_rule(rules2, CFSTR("^.*\\.lproj/"), rule(1000, 1, 0));
    set_rule(rules2, CFSTR("^.*\\.lproj/locversion.plist$"), rule(1100, 0, 1));
    set_rule(rules2, CFSTR("^(.*/)?\\.DS_Store$"), rule(2000, 0, 1));
    set_rule(rules2, CFSTR("^Base\\.lproj/"), rule(1010, 0, 0));
    set_rule(rules2, CFSTR("^Info\\.plist$"), rule(20, 0, 1));
    set_rule(rules2, CFSTR("^PkgInfo$"), rule(20, 0, 1));
    set_rule(rules2, CFSTR("^embedded\\.provisionprofile$"), rule(20, 0, 0));
    set_rule(rules2, CFSTR("^version\\.plist$"), rule(20, 0, 0));
    CFMutableDictionaryRef top = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(top, CFSTR("files"), files); CFDictionarySetValue(top, CFSTR("files2"), files2);
    CFDictionarySetValue(top, CFSTR("rules"), rules); CFDictionarySetValue(top, CFSTR("rules2"), rules2);
    CFDataRef xml = CFPropertyListCreateData(NULL, top, kCFPropertyListXMLFormat_v1_0, 0, NULL);
    CFRelease(files); CFRelease(files2); CFRelease(rules); CFRelease(rules2); CFRelease(top);
    if (!xml) return fail(err, errlen, "cannot write the resource seal");
    char dir[PATH_MAX], path[PATH_MAX];
    snprintf(dir, sizeof dir, "%s/_CodeSignature", fw); mkdir(dir, 0755);
    snprintf(path, sizeof path, "%s/CodeResources", dir);
    FILE *o = fopen(path, "wb");
    int ok = o && fwrite(CFDataGetBytePtr(xml), 1, (size_t)CFDataGetLength(xml), o) == (size_t)CFDataGetLength(xml);
    if (o) fclose(o);
    CFRelease(xml);
    return ok ? 0 : fail(err, errlen, "cannot write %s", path);
}

// ---- the CMS signature over the CodeDirectory ----
static int attr_cmp(const void *a, const void *b) {   // DER orders a SET OF by its elements' encodings
    const buf *x = a, *y = b; size_t n = x->n < y->n ? x->n : y->n; int c = memcmp(x->p, y->p, n);
    return c ? c : (x->n > y->n) - (x->n < y->n);
}
static int make_cms(const uint8_t *cd, size_t cdn, SecKeyRef key, CFArrayRef chain, buf *out, char *err, size_t errlen) {
    uint8_t h[32]; sha256(cd, cdn, h);
    CFDataRef leaf = CFArrayGetValueAtIndex(chain, 0);
    const uint8_t *iss, *ser; size_t issn, sern;
    if (!issuer_serial(leaf, &iss, &issn, &ser, &sern)) return fail(err, errlen, "cannot read the signing certificate");
    // the signed attributes
    buf at[5] = {{0}}, t = {0}, v = {0};
    der(&t, 0x06, K_CONTENT_TYPE, sizeof K_CONTENT_TYPE); der(&v, 0x06, K_DATA, sizeof K_DATA); derb(&t, 0x31, &v); derb(&at[0], 0x30, &t);
    char when[16]; time_t now = time(NULL); struct tm g; gmtime_r(&now, &g); strftime(when, sizeof when, "%y%m%d%H%M%SZ", &g);
    der(&t, 0x06, K_SIGNING_TIME, sizeof K_SIGNING_TIME); der(&v, 0x17, when, strlen(when)); derb(&t, 0x31, &v); derb(&at[1], 0x30, &t);
    der(&t, 0x06, K_MESSAGE_DIGEST, sizeof K_MESSAGE_DIGEST); der(&v, 0x04, h, 32); derb(&t, 0x31, &v); derb(&at[2], 0x30, &t);
    // Apple's: the plist of truncated CDHashes, and each CDHash with its algorithm (one SHA-256 CodeDirectory here)
    CFDataRef trunc = CFDataCreate(NULL, h, 20); CFArrayRef arr = CFArrayCreate(NULL, (const void **)&trunc, 1, &kCFTypeArrayCallBacks);
    CFStringRef kk = CFSTR("cdhashes"); CFDictionaryRef pl = CFDictionaryCreate(NULL, (const void **)&kk, (const void **)&arr, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDataRef plx = CFPropertyListCreateData(NULL, pl, kCFPropertyListXMLFormat_v1_0, 0, NULL);
    der(&t, 0x06, K_CDHASHES, sizeof K_CDHASHES); der(&v, 0x04, CFDataGetBytePtr(plx), (size_t)CFDataGetLength(plx)); derb(&t, 0x31, &v); derb(&at[3], 0x30, &t);
    CFRelease(plx); CFRelease(pl); CFRelease(arr); CFRelease(trunc);
    buf s = {0}; der(&s, 0x06, K_SHA256, sizeof K_SHA256); der(&s, 0x04, h, 32);
    der(&t, 0x06, K_CDHASHES2, sizeof K_CDHASHES2); derb(&v, 0x30, &s); derb(&t, 0x31, &v); derb(&at[4], 0x30, &t);
    qsort(at, 5, sizeof *at, attr_cmp);
    buf attrs = {0}; for (int i = 0; i < 5; i++) { put(&attrs, at[i].p, at[i].n); free(at[i].p); }
    // the signature is over the attributes encoded as a SET
    buf set = {0}; der(&set, 0x31, attrs.p, attrs.n);
    CFDataRef msg = CFDataCreate(NULL, set.p, (CFIndex)set.n); free(set.p);
    CFErrorRef ce = NULL;
    CFDataRef sig = SecKeyCreateSignature(key, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256, msg, &ce);
    CFRelease(msg);
    if (!sig) {
        CFStringRef d = ce ? CFErrorCopyDescription(ce) : NULL; char m[256] = "?"; if (d) { CFStringGetCString(d, m, sizeof m, kCFStringEncodingUTF8); CFRelease(d); }
        if (ce) CFRelease(ce); free(attrs.p);
        return fail(err, errlen, "the key would not sign: %s", m);
    }
    // SignerInfo
    buf si = {0}, x = {0};
    uint8_t one = 1; der(&si, 0x02, &one, 1);
    put(&x, iss, issn); put(&x, ser, sern); derb(&si, 0x30, &x);
    der(&x, 0x06, K_SHA256, sizeof K_SHA256); derb(&si, 0x30, &x);
    derb(&si, 0xa0, &attrs);                                      // [0] IMPLICIT signedAttrs
    der(&x, 0x06, K_RSA, sizeof K_RSA); der(&x, 0x05, NULL, 0); derb(&si, 0x30, &x);
    der(&si, 0x04, CFDataGetBytePtr(sig), (size_t)CFDataGetLength(sig)); CFRelease(sig);
    // SignedData
    buf sd = {0}; der(&sd, 0x02, &one, 1);
    der(&x, 0x06, K_SHA256, sizeof K_SHA256); buf al = {0}; derb(&al, 0x30, &x); derb(&sd, 0x31, &al);
    der(&x, 0x06, K_DATA, sizeof K_DATA); derb(&sd, 0x30, &x);   // detached content: the CodeDirectory is beside it
    for (CFIndex i = 0; i < CFArrayGetCount(chain); i++) { CFDataRef c = CFArrayGetValueAtIndex(chain, i); put(&x, CFDataGetBytePtr(c), (size_t)CFDataGetLength(c)); }
    derb(&sd, 0xa0, &x);                                          // [0] IMPLICIT certificates
    buf sis = {0}; derb(&sis, 0x30, &si); derb(&sd, 0x31, &sis);
    // ContentInfo
    buf ci = {0}; der(&ci, 0x06, K_SIGNED_DATA, sizeof K_SIGNED_DATA);
    buf e = {0}; derb(&e, 0x30, &sd); derb(&ci, 0xa0, &e);
    derb(out, 0x30, &ci);
    return 0;
}

// ---- the library ----
int dm_pack_sign(const char *fw, SecKeyRef key, CFArrayRef chain, const char *team, char *err, size_t errlen) {
    char path[PATH_MAX], tmp[PATH_MAX], exe[256] = "", ident[256] = "";
    if (!chain || CFArrayGetCount(chain) < 1) return fail(err, errlen, "no certificate");
    // Info.plist: the executable's name and the identifier
    snprintf(path, sizeof path, "%s/Info.plist", fw);
    uint8_t info_hash[32]; if (!file_hash(path, NULL, info_hash)) return fail(err, errlen, "no %s", path);
    {
        int fd = open(path, O_RDONLY); struct stat st; fstat(fd, &st);
        uint8_t *b = malloc((size_t)st.st_size); ssize_t r = read(fd, b, (size_t)st.st_size); close(fd);
        CFDataRef d = CFDataCreate(NULL, b, r > 0 ? r : 0); free(b);
        CFPropertyListRef pl = CFPropertyListCreateWithData(NULL, d, 0, NULL, NULL); CFRelease(d);
        if (!pl || CFGetTypeID(pl) != CFDictionaryGetTypeID()) { if (pl) CFRelease(pl); return fail(err, errlen, "%s cannot be read", path); }
        CFStringRef e = CFDictionaryGetValue(pl, CFSTR("CFBundleExecutable")), i = CFDictionaryGetValue(pl, CFSTR("CFBundleIdentifier"));
        if (e && CFGetTypeID(e) == CFStringGetTypeID()) CFStringGetCString(e, exe, sizeof exe, kCFStringEncodingUTF8);
        if (i && CFGetTypeID(i) == CFStringGetTypeID()) CFStringGetCString(i, ident, sizeof ident, kCFStringEncodingUTF8);
        CFRelease(pl);
        if (!exe[0] || !ident[0]) return fail(err, errlen, "%s has no CFBundleExecutable or CFBundleIdentifier", path);
    }
    if (write_resources(fw, exe, err, errlen)) return -1;
    snprintf(path, sizeof path, "%s/_CodeSignature/CodeResources", fw);
    uint8_t res_hash[32]; if (!file_hash(path, NULL, res_hash)) return fail(err, errlen, "no %s", path);

    // The executable, copied whole into memory: its load commands change, then every page is hashed
    snprintf(path, sizeof path, "%s/%s", fw, exe);
    int fd = open(path, O_RDONLY); if (fd < 0) return fail(err, errlen, "cannot open %s: %s", path, strerror(errno));
    struct stat st; fstat(fd, &st);
    uint8_t *m = mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0); close(fd);
    if (m == MAP_FAILED) return fail(err, errlen, "cannot map %s", path);
    struct mach_header_64 *mh = (struct mach_header_64 *)m;
    if ((size_t)st.st_size < sizeof *mh || mh->magic != MH_MAGIC_64 || mh->cputype != CPU_TYPE_ARM64) { munmap(m, (size_t)st.st_size); return fail(err, errlen, "%s is not a thin arm64 Mach-O", exe); }
    struct linkedit_data_command *cs = NULL; struct segment_command_64 *le = NULL, *text = NULL;
    uint8_t *lc = m + sizeof *mh;
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        struct load_command *c = (struct load_command *)lc;
        if (c->cmd == LC_CODE_SIGNATURE) cs = (struct linkedit_data_command *)c;
        if (c->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *sg = (struct segment_command_64 *)c;
            if (!strcmp(sg->segname, SEG_LINKEDIT)) le = sg;
            if (!strcmp(sg->segname, SEG_TEXT)) text = sg;
        }
        lc += c->cmdsize;
    }
    if (!cs || !le || !text) { munmap(m, (size_t)st.st_size); return fail(err, errlen, "%s has no signature load command (link it with the linker's ad-hoc signature)", exe); }
    size_t limit = cs->dataoff;   // the code ends where the old signature starts
    uint64_t exec_base = text->fileoff, exec_limit = text->filesize;   // the executable segment, read before the file is unmapped
    if (limit > (size_t)st.st_size || limit < le->fileoff) { munmap(m, (size_t)st.st_size); return fail(err, errlen, "%s: signature outside __LINKEDIT", exe); }
    size_t pages = (limit + PAGE - 1) / PAGE;
    size_t idn = strlen(ident) + 1, tmn = strlen(team) + 1;
    size_t cdn = CD_HEADER + idn + tmn + 3 * 32 + pages * 32;
    buf req = {0}; put32be(&req, CSMAGIC_REQUIREMENTS); put32be(&req, 12); put32be(&req, 0);   // an empty requirement set
    size_t sbn = 12 + 3 * 8 + cdn + req.n + 8 + CMS_RESERVE;
    size_t sign_size = (sbn + 15) & ~(size_t)15;
    // The new image: the code, its load commands telling of the new signature's size, then the signature
    uint8_t *img = malloc(limit);
    memcpy(img, m, limit); munmap(m, (size_t)st.st_size);
    {
        struct mach_header_64 *h = (struct mach_header_64 *)img; uint8_t *p = img + sizeof *h;
        for (uint32_t i = 0; i < h->ncmds; i++) {
            struct load_command *c = (struct load_command *)p;
            if (c->cmd == LC_CODE_SIGNATURE) ((struct linkedit_data_command *)c)->datasize = (uint32_t)sign_size;
            if (c->cmd == LC_SEGMENT_64 && !strcmp(((struct segment_command_64 *)c)->segname, SEG_LINKEDIT)) {
                struct segment_command_64 *sg = (struct segment_command_64 *)c;
                sg->filesize = limit + sign_size - sg->fileoff;
                sg->vmsize = (sg->filesize + 0x3fff) & ~(uint64_t)0x3fff;
            }
            p += c->cmdsize;
        }
    }
    // CodeDirectory
    buf cd = {0};
    uint32_t hashoff = (uint32_t)(CD_HEADER + idn + tmn + 3 * 32);
    put32be(&cd, CSMAGIC_CODEDIRECTORY); put32be(&cd, (uint32_t)cdn); put32be(&cd, CD_VERSION); put32be(&cd, 0);   // flags
    put32be(&cd, hashoff); put32be(&cd, CD_HEADER); put32be(&cd, 3); put32be(&cd, (uint32_t)pages); put32be(&cd, (uint32_t)limit);
    uint8_t hp[4] = {32, 2 /* SHA-256 */, 0, PAGE_BITS}; put(&cd, hp, 4); put32be(&cd, 0);   // spare2
    put32be(&cd, 0);                                         // scatterOffset
    put32be(&cd, (uint32_t)(CD_HEADER + idn));               // teamOffset
    put32be(&cd, 0); put64be(&cd, 0);                        // spare3, codeLimit64
    put64be(&cd, exec_base); put64be(&cd, exec_limit); put64be(&cd, 0);   // execSegBase, execSegLimit, execSegFlags (a library: none)
    put(&cd, ident, idn); put(&cd, team, tmn);
    uint8_t rh[32]; sha256(req.p, req.n, rh);
    put(&cd, res_hash, 32); put(&cd, rh, 32); put(&cd, info_hash, 32);   // slots −3 (resources), −2 (requirements), −1 (Info.plist)
    for (size_t i = 0; i < pages; i++) { uint8_t ph[32]; size_t o = i * PAGE; sha256(img + o, limit - o < PAGE ? limit - o : PAGE, ph); put(&cd, ph, 32); }
    if (cd.n != cdn) { free(img); free(cd.p); free(req.p); return fail(err, errlen, "CodeDirectory size %zu, expected %zu", cd.n, cdn); }
    buf cms = {0};
    if (make_cms(cd.p, cd.n, key, chain, &cms, err, errlen)) { free(img); free(cd.p); free(req.p); return -1; }
    if (cms.n + 8 > CMS_RESERVE) { free(img); free(cd.p); free(req.p); free(cms.p); return fail(err, errlen, "CMS signature of %zu bytes is larger than the room kept for it", cms.n); }
    // SuperBlob: CodeDirectory, requirements, CMS wrapper; zero padding to the size the load command gives
    buf sb = {0};
    uint32_t o_cd = 12 + 3 * 8, o_rq = o_cd + (uint32_t)cd.n, o_cm = o_rq + (uint32_t)req.n;
    put32be(&sb, CSMAGIC_EMBEDDED_SIGNATURE); put32be(&sb, o_cm + 8 + (uint32_t)cms.n); put32be(&sb, 3);
    put32be(&sb, CSSLOT_CODEDIRECTORY); put32be(&sb, o_cd); put32be(&sb, CSSLOT_REQUIREMENTS); put32be(&sb, o_rq); put32be(&sb, CSSLOT_SIGNATURESLOT); put32be(&sb, o_cm);
    put(&sb, cd.p, cd.n); put(&sb, req.p, req.n);
    put32be(&sb, CSMAGIC_BLOBWRAPPER); put32be(&sb, 8 + (uint32_t)cms.n); put(&sb, cms.p, cms.n);
    free(cd.p); free(req.p); free(cms.p);
    uint8_t *sig = calloc(1, sign_size); memcpy(sig, sb.p, sb.n); free(sb.p);
    // Written beside it and moved over it: the kernel keeps a signature per file it has seen, and a file rewritten in place keeps the old one
    snprintf(tmp, sizeof tmp, "%s.signing", path);
    int o = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0755);
    int ok = o >= 0 && write(o, img, limit) == (ssize_t)limit && write(o, sig, sign_size) == (ssize_t)sign_size;
    if (o >= 0) close(o);
    free(img); free(sig);
    if (!ok || rename(tmp, path)) { unlink(tmp); return fail(err, errlen, "cannot write %s: %s", path, strerror(errno)); }
    return 0;
}

// ---- the identity from a .p12 ----
static void cf_cstr(CFStringRef s, char *out, size_t n) { if (!out || !n) return; out[0] = 0; if (s) CFStringGetCString(s, out, (CFIndex)n, kCFStringEncodingUTF8); }
// A certificate's subject or issuer, as DER bytes (to find a certificate's issuer among the extra ones)
static CFDataRef name_of(CFDataRef cert, int subject) {
    const uint8_t *iss, *ser; size_t issn, sern;
    if (!issuer_serial(cert, &iss, &issn, &ser, &sern)) return NULL;
    if (!subject) return CFDataCreate(NULL, iss, (CFIndex)issn);
    const uint8_t *p = iss + issn, *end = CFDataGetBytePtr(cert) + CFDataGetLength(cert); size_t h, l;
    if (!tlv(p, (size_t)(end - p), &h, &l)) return NULL; p += h + l;      // validity
    if (!tlv(p, (size_t)(end - p), &h, &l)) return NULL;
    return CFDataCreate(NULL, p, (CFIndex)(h + l));                      // subject
}
// The subject's organizational unit (OID 2.5.4.11): an Apple developer certificate's team ID
static void subject_ou(CFDataRef cert, char *out, size_t n) {
    out[0] = 0; CFDataRef sub = name_of(cert, 1); if (!sub) return;
    const uint8_t *p = CFDataGetBytePtr(sub); size_t len = (size_t)CFDataGetLength(sub);
    static const uint8_t ou[] = {0x06, 0x03, 0x55, 0x04, 0x0b};
    for (size_t i = 0; i + sizeof ou + 2 < len; i++) if (!memcmp(p + i, ou, sizeof ou)) {
        const uint8_t *v = p + i + sizeof ou; size_t h, l;
        if (tlv(v, len - (size_t)(v - p), &h, &l) && l < n) { memcpy(out, v + h, l); out[l] = 0; }
        break;
    }
    CFRelease(sub);
}
int dm_pack_identity(CFDataRef p12, CFStringRef password, const char *want_team, CFArrayRef extra, SecKeyRef *key, CFArrayRef *chain, char *team, size_t teamlen,
                     char *name, size_t namelen, CFAbsoluteTime *expires, char *err, size_t errlen) {
    const void *k[] = {kSecImportExportPassphrase}, *v[] = {password ? password : CFSTR("")};
    CFDictionaryRef opt = CFDictionaryCreate(NULL, k, v, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFArrayRef items = NULL;
    OSStatus s = SecPKCS12Import(p12, opt, &items); CFRelease(opt);
    if (s != errSecSuccess || !items || CFArrayGetCount(items) < 1) { if (items) CFRelease(items); return fail(err, errlen, s == errSecAuthFailed ? "wrong password" : "not a certificate with its key (%d)", (int)s); }
    // The first identity whose certificate is an Apple Development one
    SecIdentityRef id = NULL; SecCertificateRef cert = NULL; CFArrayRef pchain = NULL; char other[32] = "";   // other: a developer certificate's team that is not the one wanted
    for (CFIndex i = 0; i < CFArrayGetCount(items) && !id; i++) {
        CFDictionaryRef it = CFArrayGetValueAtIndex(items, i);
        SecIdentityRef cand = (SecIdentityRef)CFDictionaryGetValue(it, kSecImportItemIdentity);
        SecCertificateRef c = NULL; if (!cand || SecIdentityCopyCertificate(cand, &c)) continue;
        CFStringRef sum = SecCertificateCopySubjectSummary(c); char sn[256]; cf_cstr(sum, sn, sizeof sn); if (sum) CFRelease(sum);
        char ou[32] = ""; CFDataRef cd = SecCertificateCopyData(c); subject_ou(cd, ou, sizeof ou); CFRelease(cd);
        if ((strstr(sn, "Apple Development") || strstr(sn, "iPhone Developer") || strstr(sn, "Apple Distribution")) && (!want_team || !strcmp(ou, want_team))) {
            id = cand; cert = c; pchain = CFDictionaryGetValue(it, kSecImportItemCertChain); snprintf(name, namelen, "%s", sn);
        } else {
            if (!other[0] && (strstr(sn, "Apple Development") || strstr(sn, "iPhone Developer"))) snprintf(other, sizeof other, "%s", ou);
            CFRelease(c);
        }
    }
    if (!id) {
        CFRelease(items);
        if (want_team && other[0]) return fail(err, errlen, "TEAM %s %s", other, want_team);   // PackSigner.swift words it: the certificate's team is not NX Pocket's
        return want_team ? fail(err, errlen, "no Apple developer certificate of team %s in the file", want_team) : fail(err, errlen, "no Apple developer certificate in the file");
    }
    if (SecIdentityCopyPrivateKey(id, key)) { CFRelease(cert); CFRelease(items); return fail(err, errlen, "the file has no private key"); }
    CFDataRef der0 = SecCertificateCopyData(cert); subject_ou(der0, team, teamlen); CFRelease(der0);
    if (!team[0]) { CFRelease(*key); *key = NULL; CFRelease(cert); CFRelease(items); return fail(err, errlen, "the certificate has no team"); }
    // the chain: the signer, then each issuer found in the file's chain or among the extra certificates, up to a self-signed one
    CFMutableArrayRef ch = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    CFDataRef cur = SecCertificateCopyData(cert); CFArrayAppendValue(ch, cur); CFRelease(cur);
    if (expires) { *expires = 0; CFDateRef na = SecCertificateCopyNotValidAfterDate(cert); if (na) { *expires = CFDateGetAbsoluteTime(na); CFRelease(na); } }
    CFRelease(cert);
    CFMutableArrayRef pool = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    if (pchain) for (CFIndex i = 0; i < CFArrayGetCount(pchain); i++) { CFDataRef d = SecCertificateCopyData((SecCertificateRef)CFArrayGetValueAtIndex(pchain, i)); CFArrayAppendValue(pool, d); CFRelease(d); }
    if (extra) CFArrayAppendArray(pool, extra, CFRangeMake(0, CFArrayGetCount(extra)));
    for (int depth = 0; depth < 4; depth++) {
        CFDataRef last = CFArrayGetValueAtIndex(ch, CFArrayGetCount(ch) - 1);
        CFDataRef want = name_of(last, 0), self = name_of(last, 1);
        int root = want && self && CFEqual(want, self);
        CFDataRef found = NULL;
        for (CFIndex i = 0; !root && want && i < CFArrayGetCount(pool) && !found; i++) {
            CFDataRef c = CFArrayGetValueAtIndex(pool, i), sub = name_of(c, 1);
            if (sub && CFEqual(sub, want) && !CFEqual(c, last)) found = c;
            if (sub) CFRelease(sub);
        }
        if (want) CFRelease(want); if (self) CFRelease(self);
        if (!found) break;
        CFArrayAppendValue(ch, found);
    }
    CFRelease(pool); CFRelease(items);
    *chain = ch;
    return 0;
}
