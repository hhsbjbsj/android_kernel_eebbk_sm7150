/* SPDX-License-Identifier: GPL-2.0 */
/* TCP Brutal, 4.14-adapted from Hysteria/HyNetworks tcp-brutal ABI. */
#include <linux/module.h>
#include <linux/mm.h>
#include <net/tcp.h>

#define BRUTAL_MIN_PACING_RATE (125000u)

struct brutal {
	u32 pacing_rate;
};

static void brutal_init(struct sock *sk)
{
	struct brutal *b = inet_csk_ca(sk);

	b->pacing_rate = BRUTAL_MIN_PACING_RATE;
	cmpxchg(&sk->sk_pacing_status, SK_PACING_NONE, SK_PACING_NEEDED);
	sk->sk_pacing_rate = b->pacing_rate;
}

static void brutal_cong_control(struct sock *sk, const struct rate_sample *rs)
{
	struct tcp_sock *tp = tcp_sk(sk);
	struct brutal *b = inet_csk_ca(sk);
	u32 rate = b->pacing_rate;

	if (rs->delivered < 0 || rs->interval_us <= 0)
		return;
	if (rate < BRUTAL_MIN_PACING_RATE)
		rate = BRUTAL_MIN_PACING_RATE;
	sk->sk_pacing_rate = rate;
	tp->snd_cwnd = max_t(u32, 4U, (rate / 1500U) + 4U);
}

static u32 brutal_ssthresh(struct sock *sk)
{
	return max(tcp_sk(sk)->snd_cwnd >> 1, 2U);
}

static void brutal_cong_avoid(struct sock *sk, u32 ack, u32 acked)
{
}

static u32 brutal_undo_cwnd(struct sock *sk)
{
	return tcp_sk(sk)->snd_cwnd;
}

static struct tcp_congestion_ops tcp_brutal __read_mostly = {
	.flags = TCP_CONG_NON_RESTRICTED,
	.name = "brutal",
	.owner = THIS_MODULE,
	.init = brutal_init,
	.ssthresh = brutal_ssthresh,
	.cong_avoid = brutal_cong_avoid,
	.undo_cwnd = brutal_undo_cwnd,
	.cong_control = brutal_cong_control,
};

static int __init brutal_register(void)
{
	BUILD_BUG_ON(sizeof(struct brutal) > ICSK_CA_PRIV_SIZE);
	return tcp_register_congestion_control(&tcp_brutal);
}

static void __exit brutal_unregister(void)
{
	tcp_unregister_congestion_control(&tcp_brutal);
}

module_init(brutal_register);
module_exit(brutal_unregister);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("TCP Brutal congestion control (4.14)");
