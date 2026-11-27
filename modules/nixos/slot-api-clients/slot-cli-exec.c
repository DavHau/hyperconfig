/*
 * slot-cli-exec PROG [ARGS...]: the last step of slot-api-clients' sandbox,
 * run inside landrun's Landlock domain, before the slot's binary.
 *
 *  - refuses to run unless the kernel's Landlock ABI is >= 6 (filesystem,
 *    TCP ports, scoping: what the wrapper's rules need), so a kernel without
 *    Landlock never runs the slot's code unconfined (landrun runs
 *    best-effort for the newer ABI bits);
 *  - closes every fd above 2 (a leaked socket or writable file from the
 *    caller would bypass the rules);
 *  - loads a seccomp filter: EPERM for metadata changes Landlock does not
 *    cover (chmod, chown, xattrs, timestamps, inode flags), EACCES for every
 *    socket but plain TCP over IPv4/IPv6: no MPTCP or SCTP (Landlock <=
 *    ABI 8 restricts TCP only); an unnamed socketpair stays allowed;
 *  - execs PROG.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <linux/landlock.h>
#include <netinet/in.h>
#include <seccomp.h>
#include <stdio.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/syscall.h>
#include <unistd.h>

static int deny(scmp_filter_ctx ctx, const char *name, int err) {
  int nr = seccomp_syscall_resolve_name(name);
  if (nr == __NR_SCMP_ERROR)
    return 0; /* not known to this libseccomp/arch: nothing to deny */
  return seccomp_rule_add(ctx, SCMP_ACT_ERRNO(err), nr, 0);
}

int main(int argc, char **argv) {
  if (argc < 2) {
    fprintf(stderr, "usage: slot-cli-exec PROG [ARGS...]\n");
    return 127;
  }
  long abi = syscall(SYS_landlock_create_ruleset, NULL, 0, LANDLOCK_CREATE_RULESET_VERSION);
  if (abi < 6) {
    fprintf(stderr, "slot-cli-exec: Landlock ABI %ld < 6 on this kernel; refusing to run the slot's code unconfined\n", abi);
    return 126;
  }
  if (syscall(SYS_close_range, 3U, ~0U, 0U) != 0) {
    perror("slot-cli-exec: close_range");
    return 126;
  }

  scmp_filter_ctx ctx = seccomp_init(SCMP_ACT_ALLOW);
  if (!ctx)
    return 126;
  static const char *meta[] = {
      "chmod",     "fchmod",       "fchmodat",     "fchmodat2", "chown",       "fchown",
      "lchown",    "fchownat",     "chown32",      "fchown32",  "lchown32",    "setxattr",
      "lsetxattr", "fsetxattr",    "setxattrat",   "removexattr", "lremovexattr",
      "fremovexattr", "removexattrat", "utime",     "utimes",    "futimesat",   "utimensat",
      "utimensat_time64", "file_setattr",
  };
  int rc = 0;
  for (size_t i = 0; i < sizeof meta / sizeof *meta; i++)
    rc |= deny(ctx, meta[i], EPERM);
  /* socketpair stays: an unnamed pair reaches nothing outside the process
   * (tokio's signal handling needs one). */
  /* socket(): every family but AF_INET/AF_INET6, and for those every type
   * but SOCK_STREAM (low 4 bits; SOCK_NONBLOCK/SOCK_CLOEXEC are flags). */
  for (int fam = 0; fam < AF_MAX; fam++)
    if (fam != AF_INET && fam != AF_INET6)
      rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EACCES), SCMP_SYS(socket), 1, SCMP_A0(SCMP_CMP_EQ, fam));
  rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EACCES), SCMP_SYS(socket), 1, SCMP_A0(SCMP_CMP_GE, AF_MAX));
  int fams[] = {AF_INET, AF_INET6};
  for (int f = 0; f < 2; f++) {
    for (int type = 0; type < 16; type++)
      if (type != SOCK_STREAM)
        rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EACCES), SCMP_SYS(socket), 2, SCMP_A0(SCMP_CMP_EQ, fams[f]),
                               SCMP_A1(SCMP_CMP_MASKED_EQ, 0xf, type));
    /* Protocol 0 or IPPROTO_TCP only: Landlock's TCP rules do not cover
     * MPTCP (which falls back to plain TCP, i.e. reaches every port) or
     * SCTP. Anything above IPPROTO_TCP, high bits included, fails. */
    rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EACCES), SCMP_SYS(socket), 2, SCMP_A0(SCMP_CMP_EQ, fams[f]),
                           SCMP_A2(SCMP_CMP_GT, IPPROTO_TCP));
    for (int proto = 1; proto < IPPROTO_TCP; proto++)
      rc |= seccomp_rule_add(ctx, SCMP_ACT_ERRNO(EACCES), SCMP_SYS(socket), 2, SCMP_A0(SCMP_CMP_EQ, fams[f]),
                             SCMP_A2(SCMP_CMP_EQ, proto));
  }
  if (rc != 0 || seccomp_load(ctx) != 0) {
    fprintf(stderr, "slot-cli-exec: could not load the seccomp filter\n");
    return 126;
  }
  seccomp_release(ctx);
  execv(argv[1], argv + 1);
  fprintf(stderr, "slot-cli-exec: exec %s: %s\n", argv[1], strerror(errno));
  return 127;
}
