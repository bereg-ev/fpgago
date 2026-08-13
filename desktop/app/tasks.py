"""tasks.py — running blocking work off the GUI thread.

Lifted out of main.py so modules below it (shotgrab.py) can start background
work without importing the window that starts them.
"""

from __future__ import annotations

import traceback

from PySide6.QtCore import Qt, QObject, QRunnable, QThreadPool, Signal


class _TaskSignals(QObject):
    done = Signal(object)
    error = Signal(str)
    progress = Signal(str)


class Task(QRunnable):
    """Run fn(*args, **kwargs) off the GUI thread. If `wants_progress`, a
    `progress=` callback is injected that re-emits on the signal.

    Start Tasks through start_task() below, never pool.start() directly."""

    def __init__(self, fn, *args, wants_progress=False, **kwargs):
        super().__init__()
        self.setAutoDelete(False)      # lifetime owned by _live_tasks
        self.fn, self.args, self.kwargs = fn, args, kwargs
        self.wants_progress = wants_progress
        self.signals = _TaskSignals()

    def run(self):
        try:
            if self.wants_progress:
                self.kwargs["progress"] = self.signals.progress.emit
            self.signals.done.emit(self.fn(*self.args, **self.kwargs))
        except RuntimeError:
            pass          # app teardown deleted the signal proxy — drop
        except Exception:                            # noqa: BLE001
            try:
                self.signals.error.emit(traceback.format_exc())
            except RuntimeError:
                pass


# Signals connected to plain Python callables (lambdas) are delivered in the
# EMITTING thread — for a Task that is the pool worker, and touching widgets
# there segfaults sooner or later.  start_task() therefore connects every
# callback with an explicit QueuedConnection (the proxy receiver is created
# on the GUI thread, so callbacks always run there) and keeps the Task alive
# until its callbacks have been delivered (autoDelete would let the C++ side
# destroy the runnable + signals from the worker thread).
_live_tasks: set = set()


def start_task(pool: QThreadPool, task: Task, on_done=None, on_error=None,
               on_progress=None):
    q = Qt.ConnectionType.QueuedConnection
    if on_done is not None:
        task.signals.done.connect(on_done, q)
    if on_error is not None:
        task.signals.error.connect(on_error, q)
    if on_progress is not None:
        task.signals.progress.connect(on_progress, q)
    _live_tasks.add(task)
    # connected last → delivered after the user callbacks above
    task.signals.done.connect(lambda _r: _live_tasks.discard(task), q)
    task.signals.error.connect(lambda _e: _live_tasks.discard(task), q)
    pool.start(task)
