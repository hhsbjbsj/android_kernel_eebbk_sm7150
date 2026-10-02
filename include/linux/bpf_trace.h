/* SPDX-License-Identifier: GPL-2.0 */
#ifndef __LINUX_BPF_TRACE_H__
#define __LINUX_BPF_TRACE_H__

#include <trace/events/bpf.h>
#include <trace/events/xdp.h>
#include <linux/trace_events.h>

struct bpf_raw_event_map;
struct bpf_prog;

#ifndef bpf_probe_register
int bpf_probe_register(struct bpf_raw_event_map *btp, struct bpf_prog *prog);
int bpf_probe_unregister(struct bpf_raw_event_map *btp, struct bpf_prog *prog);
struct bpf_raw_event_map *bpf_find_raw_tracepoint(const char *name);
#endif

#endif /* __LINUX_BPF_TRACE_H__ */
