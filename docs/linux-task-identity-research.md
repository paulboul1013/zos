# Linux task 身分與回收調查

調查日期：2026-10-03。本文核對上游固定標籤 `v2.6.12`、`v4.19`、`v5.3` 與 `v6.12`。
調查時 Q6 尚未決定。後續訪談已確認 generation 不循環與用盡後停用 slot，完整契約見[設計文件](task-lifecycle-plan.md)。本文保留調查當時的比較與推論。

## 已查證的結論

這四個版本都允許數字 PID 循環與重用。配置器到達上限後，會搜尋可用的舊號碼。它們沒有採用「世代用盡就永久停用 task slot」的規則。[v2.6.12 配置器](https://github.com/torvalds/linux/blob/v2.6.12/kernel/pid.c#L60-L125)、[v4.19 配置器](https://github.com/torvalds/linux/blob/v4.19/kernel/pid.c#L149-L188)、[v5.3 配置器](https://github.com/torvalds/linux/blob/v5.3/kernel/pid.c#L150-L188)、[v6.12 配置器](https://github.com/torvalds/linux/blob/v6.12/kernel/pid.c#L214-L234)

Linux 明確承認：保存數字 PID，稍後再查詢，可能找到重用同一號碼的新 process。`v4.19` 與 `v6.12` 的核心使用獨立的 `struct pid` 物件及引用，讓持有者保持原來的身分。這不是把 generation 編入公開 PID。[v4.19 身分說明與結構](https://github.com/torvalds/linux/blob/v4.19/include/linux/pid.h#L23-L69)、[v6.12 身分說明與結構](https://github.com/torvalds/linux/blob/v6.12/include/linux/pid.h#L19-L79)

## 版本差異

| 固定版本 | 數字 PID 配置與重用 | 核心 PID 物件 |
| --- | --- | --- |
| `v2.6.12` | `alloc_pidmap()` 使用 bitmap。到達 `pid_max` 後回到 `RESERVED_PIDS`。`free_pidmap()` 清除配置位元。[來源](https://github.com/torvalds/linux/blob/v2.6.12/kernel/pid.c#L60-L125) | `struct pid` 直接內嵌於 `task_struct.pids[]`。它包含號碼與串列欄位，尚不是後來的獨立引用物件。[結構](https://github.com/torvalds/linux/blob/v2.6.12/include/linux/pid.h#L13-L21)、[內嵌欄位](https://github.com/torvalds/linux/blob/v2.6.12/include/linux/sched.h#L585-L586) |
| `v4.19` | 每個 PID namespace 使用 IDR。`alloc_pid()` 呼叫 `idr_alloc_cyclic()`，後者到達上限後重新搜尋範圍起點。[PID 配置](https://github.com/torvalds/linux/blob/v4.19/kernel/pid.c#L149-L193)、[循環實作](https://github.com/torvalds/linux/blob/v4.19/lib/idr.c#L113-L129) | `alloc_pid()` 從 slab 配置獨立物件。`get_pid()` 增加 `atomic_t count`。[配置](https://github.com/torvalds/linux/blob/v4.19/kernel/pid.c#L149-L163)、[引用](https://github.com/torvalds/linux/blob/v4.19/include/linux/pid.h#L53-L69) |
| `v5.3` | 繼續使用 `idr_alloc_cyclic()`，數字 PID 仍可重用。[配置](https://github.com/torvalds/linux/blob/v5.3/kernel/pid.c#L150-L188) | `pidfd_open()` 讓使用者持有引用原身分物件的 FD。`pidfd_create()` 以 `get_pid()` 取得引用，使用 anonymous inode 建立 FD。[pidfd 建立與開啟](https://github.com/torvalds/linux/blob/v5.3/kernel/pid.c#L431-L493) |
| `v6.12` | 一般配置仍使用 `idr_alloc_cyclic()`。指定 `set_tid` 時另走指定號碼的 `idr_alloc()`。[PID 配置](https://github.com/torvalds/linux/blob/v6.12/kernel/pid.c#L183-L239)、[循環實作](https://github.com/torvalds/linux/blob/v6.12/lib/idr.c#L110-L126) | 仍配置獨立物件。引用計數改用 `refcount_t`。結構另包含 pidfd 等待佇列。[配置](https://github.com/torvalds/linux/blob/v6.12/kernel/pid.c#L176-L178)、[結構與引用](https://github.com/torvalds/linux/blob/v6.12/include/linux/pid.h#L50-L79) |

## pidfd 與核心執行緒的身分保證

pidfd 相關 API 分階段加入：`pidfd_send_signal()` 始於 Linux 5.1，`CLONE_PIDFD` 始於 5.2，`pidfd_open()` 始於 5.3。`v5.3` 的開啟介面只接受 thread-group leader。`v6.12` 另接受 `PIDFD_THREAD`。[signal 手冊](https://man7.org/linux/man-pages/man2/pidfd_send_signal.2.html)、[clone 手冊](https://man7.org/linux/man-pages/man2/clone.2.html)、[open 手冊](https://man7.org/linux/man-pages/man2/pidfd_open.2.html)、[v5.3 實作](https://github.com/torvalds/linux/blob/v5.3/kernel/pid.c#L455-L493)、[v6.12 實作](https://github.com/torvalds/linux/blob/v6.12/kernel/pid.c#L579-L610)

持有正確的 pidfd 時，對舊 process 的操作不會因數字 PID 重用而改指新 process。原目標終止並被收取後，`pidfd_send_signal()` 回傳 `ESRCH`。`v6.12` 的 pidfd 檔案透過 pidfs 取得 `struct pid` 引用，inode 回收時才放下該引用。[API 保證](https://man7.org/linux/man-pages/man2/pidfd_send_signal.2.html)、[pidfs 取得引用](https://github.com/torvalds/linux/blob/v6.12/fs/pidfs.c#L374-L387)、[pidfs 釋放引用](https://github.com/torvalds/linux/blob/v6.12/fs/pidfs.c#L303-L309)

取得 pidfd 本身仍有前置條件。如果目標已退出且 PID 在 `pidfd_open(pid)` 前就被重用，僅憑舊數字無法還原原目標。子 process 尚未被收取的情況有手冊所列保證，其他情況可在建立時使用 `CLONE_PIDFD` 取得引用。關閉 FD 後，FD 號碼也可重用，持有舊整數不等於仍持有原引用。[取得時的條件](https://man7.org/linux/man-pages/man2/pidfd_open.2.html)、[建立時取得](https://man7.org/linux/man-pages/man2/clone.2.html)、[FD 重用](https://man7.org/linux/man-pages/man2/close.2.html)

更接近 ZOS 的 kernel thread API 也使用物件生命週期：`v6.12` 的 `kthread_stop()` 接受 `task_struct *`。它的契約要求：若 thread 可能自行退出，呼叫者必須確保該物件仍存在。裸指標本身不提供有效性保證。[kthread 契約與實作](https://github.com/torvalds/linux/blob/v6.12/kernel/kthread.c#L640-L689)

## 號碼、身分物件與 stack 的回收時點

在 `v4.19` 與 `v6.12`，最後一個 PID 類型的 task 連結移除後，核心呼叫 `free_pid()`。它先從 namespace 的 IDR 移除號碼，然後透過 RCU 延後放下配置器的物件引用。外部引用仍可保留舊 `struct pid`，但數字號碼已能重新配置。最後一個引用釋放時，`put_pid()` 才釋放物件。[v4.19 解除連結](https://github.com/torvalds/linux/blob/v4.19/kernel/pid.c#L268-L289)、[v4.19 回收](https://github.com/torvalds/linux/blob/v4.19/kernel/pid.c#L94-L147)、[v6.12 解除連結](https://github.com/torvalds/linux/blob/v6.12/kernel/pid.c#L325-L346)、[v6.12 回收](https://github.com/torvalds/linux/blob/v6.12/kernel/pid.c#L106-L155)

因此，正確持有舊物件的引用，不會讓它變成新 process 的物件。這個保證只涵蓋持有引用的期間。它不會讓數字 PID 永久唯一。[v6.12 身分說明](https://github.com/torvalds/linux/blob/v6.12/include/linux/pid.h#L19-L35)、[v6.12 最後引用釋放](https://github.com/torvalds/linux/blob/v6.12/kernel/pid.c#L106-L117)

三個版本都區分退出與收取。需要等待父 process 收取的 task 會保留 `EXIT_ZOMBIE`。符合自動收取條件的 task 則走 `EXIT_DEAD` 與 `release_task()`。因此，Linux 的退出語意不能直接當成 ZOS Q1 的自動回收契約。[v2.6.12 退出通知](https://github.com/torvalds/linux/blob/v2.6.12/kernel/exit.c#L704-L721)、[v4.19 退出通知](https://github.com/torvalds/linux/blob/v4.19/kernel/exit.c#L668-L700)、[v6.12 退出通知](https://github.com/torvalds/linux/blob/v6.12/kernel/exit.c#L689-L736)

`v2.6.12` 在切換後的 `finish_task_switch()` 放下死亡 task 的 current 引用。最終的 `free_task()` 釋放 `thread_info` 與 `task_struct`。[切換後處理](https://github.com/torvalds/linux/blob/v2.6.12/kernel/sched.c#L1229-L1262)、[最終回收](https://github.com/torvalds/linux/blob/v2.6.12/kernel/fork.c#L101-L121)

`v4.19` 與 `v6.12` 在切換後，對 `TASK_DEAD` 的前一個 task 呼叫 `put_task_stack()`。啟用 `CONFIG_THREAD_INFO_IN_TASK` 時，stack 引用數歸零才釋放。未啟用時，`free_task()` 負責釋放 stack。CPU 離開 stack 與 stack 實際回收因此不是同一事件。[v4.19 切換後處理](https://github.com/torvalds/linux/blob/v4.19/kernel/sched/core.c#L2534-L2546)、[v4.19 stack 回收](https://github.com/torvalds/linux/blob/v4.19/kernel/fork.c#L354-L388)、[v6.12 切換後處理](https://github.com/torvalds/linux/blob/v6.12/kernel/sched/core.c#L4925-L4932)、[v6.12 stack 回收](https://github.com/torvalds/linux/blob/v6.12/kernel/fork.c#L540-L574)

## 對 ZOS 的意義與限制

以下是設計推論，不是 Linux 的實作規則。Linux 的重用問題與 ZOS Q2 相同：儲存位置或數字相同，不代表仍是同一次生命週期。ZOS 的 slot 加 generation 可讓值型 Task ID 區分不同生命週期。Linux 則在上述現代版本，用被引用的身分物件保留區別。[問題與物件方案的上游說明](https://github.com/torvalds/linux/blob/v6.12/include/linux/pid.h#L19-L35)

「使用 generation」與「用盡後永久停用 slot」是兩個決定。前者處理一般重用。後者處理有限 ID 空間的極端邊界。Linux 的調查支持必須處理身分重用問題，但沒有替 ZOS 決定 Q6。ID 位寬、是否允許循環、舊 ID 的有效期間，以及計數器上限仍須分別確認。

## 為什麼 ZOS 提出 generation

ZOS 目前有固定的四格 table，呼叫者以可直接複製的數字查詢 task。A 與 B 先後使用 slot 2 時，只比較 slot 無法分辨兩次生命週期。比較 `(slot, generation)` 可以拒絕舊世代的查詢，不必先引入身分物件的取得與釋放 API。這是針對 ZOS 現有介面與 Q2 的設計推論。[目前 API](../kernel/task.zc)、[已確認的 Q2](task-lifecycle-plan.md)

此概念也見於 generational arena 的作者文件。作者用 index 加 generation 解決刪除與重用後，舊 index 誤指新物件的問題。這是 generation 機制的參考來源，不是 Linux PID 編碼的來源。[作者文件，頁面版本 0.2.9](https://docs.rs/generational-arena/latest/generational_arena/)

永久停用方案需要額外的嚴格條件：ID 維持固定寬度，而且任何舊數值在任意久之後都不得再次識別新 task。固定寬度只有有限個值，因此這個條件與無限次成功建立不能同時成立。這是有限集合的推論。改用更寬的 ID 會延後用盡，仍須定義用盡行為。

調查時 Q2 已確認一般 slot 重用時以 generation 拒絕舊 ID，「任意久之後也永久拒絕」的保證強度則尚未另行確認。
當時的 30-bit generation、停用 slot 與累計數上限，均屬 Q6 的條件式建議。
若改用 Linux 式引用方案，則須重新定義取得、持有與釋放識別的契約，並安排可與 stack 分開存活的身分記錄。

## 調查限制

本次核對四個上游版本的 PID 與識別介面，退出與 stack 比較涵蓋 `v2.6.12`、`v4.19` 與 `v6.12`。本文沒有宣稱涵蓋所有 Linux 版本、穩定版修補或所有架構。stack 回收受核心設定、額外引用與架構影響。本文沒有採用註解中的歷史記憶體大小估計。本文也沒有把 Linux 的 PID 當成 ZOS 的靜態 slot 編號。
