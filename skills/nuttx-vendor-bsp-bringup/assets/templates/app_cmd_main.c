/****************************************************************************
 * <PLACEHOLDER: file header>
 *
 * <peripheral> bring-up test command.
 *
 * Verification goal : <what data-path property this proves>
 * Device node       : <e.g. /dev/xxx0>
 * PASS criterion    : <observable condition, e.g. two reads share one CRC32>
 ****************************************************************************/

#include <nuttx/config.h>

#include <errno.h>
#include <fcntl.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <syslog.h>

/****************************************************************************
 * Pre-processor Definitions
 ****************************************************************************/

#define XXX_DEVNAME     "/dev/xxx0"
#define XXX_DEFAULT_ARG 10
#define XXX_MIN_ARG     1
#define XXX_MAX_ARG     300

/****************************************************************************
 * Private Functions
 ****************************************************************************/

static void xxx_usage(FAR const char *progname)
{
  fprintf(stderr, "Usage: %s [%d..%d]\n", progname, XXX_MIN_ARG, XXX_MAX_ARG);
}

/****************************************************************************
 * Public Functions
 ****************************************************************************/

int main(int argc, FAR char *argv[])
{
  int arg = XXX_DEFAULT_ARG;
  int fd;
  int ret;

  /* 1. Parse and bounds-check every argument. Give a usable range message. */

  if (argc > 1)
    {
      arg = atoi(argv[1]);
      if (arg < XXX_MIN_ARG || arg > XXX_MAX_ARG)
        {
          xxx_usage(argv[0]);
          return EXIT_FAILURE;
        }
    }

  /* 2. Open through the standard device node. */

  fd = open(XXX_DEVNAME, O_RDWR | O_CLOEXEC);
  if (fd < 0)
    {
      int errcode = errno;
      fprintf(stderr, "%s: open %s failed: %d\n", argv[0], XXX_DEVNAME,
              errcode);
      return EXIT_FAILURE;
    }

  /* 3. Configure, then exercise the real data path. */

  ret = ioctl(fd, XXXIOC_CONFIGURE, arg);
  if (ret < 0)
    {
      int errcode = errno;
      fprintf(stderr, "%s: configure failed: %d\n", argv[0], errcode);
      (void)close(fd);
      return EXIT_FAILURE;
    }

  /* 4. Collect the observable evidence used by the PASS/FAIL judgement. */

  ret = <PLACEHOLDER: perform the data-path operation>;
  if (ret < 0)
    {
      int errcode = errno;
      fprintf(stderr, "%s: operation failed: %d\n", argv[0], errcode);
      (void)close(fd);
      return EXIT_FAILURE;
    }

  /* 5. Report an explicit, reproducible verdict (not just "done"). */

  if (<PLACEHOLDER: criterion holds>)
    {
      printf("%s: PASS; <describe what was proven>\n", argv[0]);
    }
  else
    {
      printf("%s: FAIL; <describe the mismatch>\n", argv[0]);
      (void)close(fd);
      return EXIT_FAILURE;
    }

  /* 6. Release every resource on every exit path. */

  (void)close(fd);
  return EXIT_SUCCESS;
}
