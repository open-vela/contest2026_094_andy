/****************************************************************************
 * <board>_bringup.c — board-level peripheral registration
 *
 * Rules encoded here:
 *   - every registration logs its result (a silent failure is the most
 *     expensive kind)
 *   - registrations run in board_late_initialize(): scheduler ready, bus I/O
 *     and blocking are legal
 *   - long operations (mount, network) go to a worker, never block bringup
 *   - ordering follows the dependency: bus -> device -> framework -> fs
 ****************************************************************************/

#include <nuttx/config.h>

#include <errno.h>
#include <syslog.h>

#include <nuttx/board.h>
#include <nuttx/i2c/i2c_master.h>
#include <nuttx/input/buttons.h>
#include <nuttx/video/fb.h>

#include "board.h"

/****************************************************************************
 * Private Functions
 ****************************************************************************/

#ifdef CONFIG_<SOC>_SDMC1
static int <board>_mount_worker(int argc, FAR char *argv[])
{
  int ret;

  UNUSED(argc);
  UNUSED(argv);

  /* Mounting can take seconds: keep it off the bringup path. */

  ret = <soc>_sdmc1_mount();
  if (ret < 0)
    {
      syslog(LOG_ERR, "[<BOARD>] mount failed: %d\n", ret);
    }
  else
    {
      syslog(LOG_INFO, "[<BOARD>] mounted\n");
    }

  return ret;
}
#endif

/****************************************************************************
 * Public Functions
 ****************************************************************************/

int <board>_bringup(void)
{
  int result = OK;
  int ret;

  /* 1. Pinmux first: everything below assumes the pads are already routed. */

  <soc>_board_pinmux_init();

  /* 2. Bus controllers: no device can be reached before this succeeds. */

#ifdef CONFIG_<SOC>_I2C
  ret = <soc>_i2c_initialize();
  if (ret < 0)
    {
      syslog(LOG_ERR, "[<BOARD>] i2c init failed: %d\n", ret);
      result = ret;
    }
  else
    {
      syslog(LOG_INFO, "[<BOARD>] i2c ready\n");
    }
#endif

  /* 3. Devices on those buses, then the framework registration they feed. */

#ifdef CONFIG_<SOC>_TOUCH
  ret = <soc>_touch_initialize();
  if (ret < 0)
    {
      syslog(LOG_ERR, "[<BOARD>] touch init failed: %d\n", ret);
      result = ret;
    }
  else
    {
      syslog(LOG_INFO, "[<BOARD>] touch registered\n");
    }
#endif

  /* 4. Framebuffer + backlight: display engine must be stable first. */

#ifdef CONFIG_<SOC>_DISPLAY
  ret = <soc>_fb_initialize();
  if (ret < 0)
    {
      syslog(LOG_ERR, "[<BOARD>] fb init failed: %d\n", ret);
      result = ret;
    }
  else
    {
      syslog(LOG_INFO, "[<BOARD>] fb0 registered\n");
    }
#endif

  /* 5. Deferred work: filesystem mounts, network bring-up. */

#ifdef CONFIG_<SOC>_SDMC1
  ret = kthread_create("<board>-mount", SCHED_PRIORITY_DEFAULT - 10, 4096,
                       <board>_mount_worker, NULL, NULL);
  if (ret < 0)
    {
      syslog(LOG_ERR, "[<BOARD>] mount worker create failed: %d\n", ret);
      result = ret;
    }
#endif

  return result;
}

/****************************************************************************
 * board hooks
 ****************************************************************************/

#ifdef CONFIG_BOARD_EARLY_INITIALIZE
void board_early_initialize(void)
{
  /* Minimal only: do not reconfigure what the previous boot stage set up,
   * do not block, do not touch the heap.
   */
}
#endif

#ifdef CONFIG_BOARD_LATE_INITIALIZE
void board_late_initialize(void)
{
  (void)<board>_bringup();
}
#endif
