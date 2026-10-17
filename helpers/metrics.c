// Small, read-only macOS CPU/RAM sampler; no top/system_profiler polling.
#include <mach/mach.h>
#include <mach/processor_info.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <unistd.h>

int main(void) {
  natural_t before_count = 0, after_count = 0;
  mach_msg_type_number_t before_size = 0, after_size = 0;
  processor_info_array_t before = NULL, after = NULL;
  host_t host = mach_host_self();
  if (host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &before_count,
                          &before, &before_size) != KERN_SUCCESS) return 1;
  usleep(200000);
  if (host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &after_count,
                          &after, &after_size) != KERN_SUCCESS) {
    vm_deallocate(mach_task_self(), (vm_address_t)before, before_size * sizeof(integer_t));
    return 1;
  }
  double busy_total = 0, ticks_total = 0, group_busy[4] = {0}, group_ticks[4] = {0};
  natural_t count = before_count < after_count ? before_count : after_count;
  for (natural_t cpu = 0; cpu < count; cpu++) {
    double ticks = 0, idle = 0;
    for (int state = 0; state < CPU_STATE_MAX; state++) {
      size_t index = cpu * CPU_STATE_MAX + state;
      uint32_t delta = (uint32_t)after[index] - (uint32_t)before[index];
      ticks += delta;
      if (state == CPU_STATE_IDLE) idle = delta;
    }
    int group = cpu * 4 / count;
    group_busy[group] += ticks - idle;
    group_ticks[group] += ticks;
    busy_total += ticks - idle;
    ticks_total += ticks;
  }
  vm_deallocate(mach_task_self(), (vm_address_t)before, before_size * sizeof(integer_t));
  vm_deallocate(mach_task_self(), (vm_address_t)after, after_size * sizeof(integer_t));

  vm_statistics64_data_t vm = {0};
  mach_msg_type_number_t vm_size = HOST_VM_INFO64_COUNT;
  vm_size_t page_size = 0;
  host_page_size(host, &page_size);
  if (host_statistics64(host, HOST_VM_INFO64, (host_info64_t)&vm, &vm_size) != KERN_SUCCESS) return 1;
  uint64_t physical = 0;
  size_t physical_size = sizeof(physical);
  if (sysctlbyname("hw.memsize", &physical, &physical_size, NULL, 0) != 0) return 1;
  // App (anonymous minus purgeable), wired, and compressed memory, excluding file cache.
  uint64_t app_pages = vm.internal_page_count > vm.purgeable_count
      ? vm.internal_page_count - vm.purgeable_count : 0;
  double used = (double)(app_pages + vm.wire_count + vm.compressor_page_count) * page_size;
  printf("{\"cpu\":%.1f,\"cores\":[", ticks_total ? busy_total / ticks_total * 100 : 0);
  for (int group = 0; group < 4; group++) {
    printf("%s%.1f", group ? "," : "", group_ticks[group] ? group_busy[group] / group_ticks[group] * 100 : 0);
  }
  printf("],\"used\":%.1f,\"total\":%.1f}\n", used / 1073741824., physical / 1073741824.);
  mach_port_deallocate(mach_task_self(), host);
  return 0;
}
