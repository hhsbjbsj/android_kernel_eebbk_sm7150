// SPDX-License-Identifier: GPL-2.0
#include <linux/fs.h>
#include <linux/init.h>
#include <linux/proc_fs.h>
#include <linux/seq_file.h>
#include <linux/uaccess.h>
#include <linux/printk.h>

static ssize_t bootprof_proc_write(struct file *file, const char __user *buf,
				   size_t count, loff_t *pos)
{
	char kbuf[256];
	size_t len = min(count, sizeof(kbuf) - 1);

	if (copy_from_user(kbuf, buf, len))
		return -EFAULT;

	kbuf[len] = '\0';
	if (len > 0 && kbuf[len - 1] == '\n')
		kbuf[len - 1] = '\0';

	pr_info("bootprof: %s\n", kbuf);
	return count;
}

static ssize_t bootprof_proc_read(struct file *file, char __user *buf,
				  size_t count, loff_t *pos)
{
	return 0;
}

static const struct file_operations bootprof_proc_fops = {
	.read		= bootprof_proc_read,
	.write		= bootprof_proc_write,
	.llseek		= noop_llseek,
};

static int __init proc_bootprof_init(void)
{
	proc_create("bootprof", 0666, NULL, &bootprof_proc_fops);
	return 0;
}
fs_initcall(proc_bootprof_init);
