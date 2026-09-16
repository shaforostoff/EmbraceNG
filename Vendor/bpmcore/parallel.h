#ifndef BPMCORE_PARALLEL_H
#define BPMCORE_PARALLEL_H

// Threading for the stages worth spreading across cores.
//
// Every user of this divides its work into blocks whose results do not depend
// on how the division was made, so one thread and eight produce the same
// answer bit for bit. That is not incidental: a tempo that moved with the
// machine it was measured on would be useless for a tag, and the test harness
// checks it.

#include <algorithm>
#include <atomic>
#include <thread>
#include <vector>

namespace bpmcore
{

//! Threads to use for `items` units of work.
//!
//! `requested` is 0 to decide from the hardware and 1 to stay on the calling
//! thread. `min_items_per_thread` is the point below which a block is not worth
//! a thread hand-off.
inline int resolve_threads(int requested, int items, int min_items_per_thread)
{
	if (requested == 1) return 1;
	int n = requested;
	if (n <= 0)
	{
		n = static_cast<int>(std::thread::hardware_concurrency());
		if (n <= 0) n = 1;
		// Past this the work stops being the bottleneck and the scheduler noise
		// costs more than the extra core returns.
		n = std::min(n, 8);
	}
	n = std::min(n, std::max(1, items / std::max(1, min_items_per_thread)));
	return std::max(1, n);
}

//! Calls `body(i)` for every i in [0, blocks), across `threads` threads.
//!
//! Blocks are handed out from a shared counter rather than split evenly, so a
//! core that is busy with something else does not hold up the rest. The calling
//! thread takes blocks too.
template<typename body_t>
void parallel_blocks(int blocks, int threads, body_t body)
{
	if (blocks <= 0) return;
	if (threads <= 1 || blocks == 1)
	{
		for (int i = 0; i < blocks; i++) body(i);
		return;
	}

	std::atomic<int> next(0);
	const auto take = [&next, blocks, &body]()
	{
		for (;;)
		{
			const int i = next.fetch_add(1);
			if (i >= blocks) return;
			body(i);
		}
	};

	std::vector<std::thread> pool;
	pool.reserve(static_cast<std::size_t>(threads - 1));
	for (int t = 0; t < threads - 1; t++) pool.emplace_back(take);
	take();
	for (std::size_t t = 0; t < pool.size(); t++) pool[t].join();
}

}   // namespace bpmcore

#endif // BPMCORE_PARALLEL_H
