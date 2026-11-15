#include <errno.h>
#include <inttypes.h>
#include <libproc.h>
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/resource.h>
#include <time.h>

static int snapshot(int pid, struct rusage_info_v6 *usage) {
    return proc_pid_rusage(pid, RUSAGE_INFO_V6, (rusage_info_t *)usage);
}

static double monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec + now.tv_nsec / 1e9;
}

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "Usage: sample-idle PID SECONDS\n");
        return 2;
    }
    int pid = atoi(argv[1]);
    int seconds = atoi(argv[2]);
    if (pid <= 0 || seconds <= 0) { return 2; }

    mach_timebase_info_data_t clock;
    mach_timebase_info(&clock);
    double nanoseconds_per_tick = (double)clock.numer / clock.denom;
    struct rusage_info_v6 before = {0};
    struct rusage_info_v6 after = {0};
    double start = monotonic_seconds();
    if (snapshot(pid, &before) != 0) { perror("initial process sample"); return 1; }

    struct timespec remaining = { .tv_sec = seconds };
    while (nanosleep(&remaining, &remaining) == -1 && errno == EINTR) {}
    if (snapshot(pid, &after) != 0) { perror("final process sample"); return 1; }
    if (after.ri_proc_start_abstime != before.ri_proc_start_abstime) {
        fprintf(stderr, "Process changed during the sample.\n");
        return 1;
    }
    double elapsed = monotonic_seconds() - start;
    uint64_t own_ticks = (after.ri_user_time - before.ri_user_time) +
        (after.ri_system_time - before.ri_system_time);
    uint64_t child_ticks = (after.ri_child_user_time - before.ri_child_user_time) +
        (after.ri_child_system_time - before.ri_child_system_time);
    uint64_t own_wakeups = after.ri_interrupt_wkups - before.ri_interrupt_wkups;
    uint64_t child_wakeups = after.ri_child_interrupt_wkups - before.ri_child_interrupt_wkups;
    double own_cpu = own_ticks * nanoseconds_per_tick / 1e7 / elapsed;
    double child_cpu = child_ticks * nanoseconds_per_tick / 1e7 / elapsed;
    printf("elapsed_s=%.2f\napp_cpu_pct=%.6f\nexited_children_cpu_pct=%.6f\n",
           elapsed, own_cpu, child_cpu);
    printf("total_named_cpu_pct=%.6f\napp_interrupt_wakeups=%" PRIu64 "\n",
           own_cpu + child_cpu, own_wakeups);
    printf("exited_children_interrupt_wakeups=%" PRIu64 "\napp_cpu_power_mw=%.6f\n",
           child_wakeups, (after.ri_energy_nj - before.ri_energy_nj) / 1e6 / elapsed);
    printf("app_memory_mib=%.2f\n", after.ri_phys_footprint / 1048576.0);
    return 0;
}
