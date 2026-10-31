#pragma once

// libdispatch's hooks for a run loop that serves the main queue, as Foundation's run loop uses them on
// Windows: the event that is signaled when the main queue has work, and the call that does that work.
__declspec(dllimport) void *_dispatch_get_main_queue_handle_4CF(void);
__declspec(dllimport) void _dispatch_main_queue_callback_4CF(void *unused);
