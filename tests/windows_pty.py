"""Minimal ConPTY integration fixture; imports only on Windows.

API sequence follows Microsoft's Creating a Pseudoconsole Session guide.
"""
from __future__ import annotations

import ctypes as c
import subprocess
import threading
import time
from ctypes import wintypes as w


class Coord(c.Structure):
    _fields_ = [("X", c.c_short), ("Y", c.c_short)]


class Startup(c.Structure):
    _fields_ = [("cb", w.DWORD), ("reserved", w.LPWSTR), ("desktop", w.LPWSTR),
                ("title", w.LPWSTR), ("x", w.DWORD), ("y", w.DWORD),
                ("width", w.DWORD), ("height", w.DWORD), ("xchars", w.DWORD),
                ("ychars", w.DWORD), ("fill", w.DWORD), ("flags", w.DWORD),
                ("show", w.WORD), ("reserved_size", w.WORD), ("reserved_ptr", c.c_void_p),
                ("stdin", w.HANDLE), ("stdout", w.HANDLE), ("stderr", w.HANDLE)]


class StartupEx(c.Structure):
    _fields_ = [("startup", Startup), ("attributes", c.c_void_p)]


class ProcessInfo(c.Structure):
    _fields_ = [("process", w.HANDLE), ("thread", w.HANDLE), ("pid", w.DWORD), ("tid", w.DWORD)]


class Console:
    def __init__(self, argv: list[str]):
        self.api = api = c.WinDLL("kernel32", use_last_error=True)
        pointer = c.c_void_p
        handle_pointer = c.POINTER(w.HANDLE)
        prototypes = {
            "CreatePipe": ([handle_pointer, handle_pointer, pointer, w.DWORD], w.BOOL),
            "CreatePseudoConsole": ([Coord, w.HANDLE, w.HANDLE, w.DWORD, handle_pointer], c.c_long),
            "ResizePseudoConsole": ([w.HANDLE, Coord], c.c_long),
            "ClosePseudoConsole": ([w.HANDLE], None),
            "CloseHandle": ([w.HANDLE], w.BOOL),
            "InitializeProcThreadAttributeList": ([pointer, w.DWORD, w.DWORD, c.POINTER(c.c_size_t)], w.BOOL),
            "UpdateProcThreadAttribute": ([pointer, w.DWORD, c.c_size_t, pointer, c.c_size_t, pointer, pointer], w.BOOL),
            "DeleteProcThreadAttributeList": ([pointer], None),
            "CreateProcessW": ([w.LPCWSTR, w.LPWSTR, pointer, pointer, w.BOOL, w.DWORD, pointer, w.LPCWSTR, pointer, c.POINTER(ProcessInfo)], w.BOOL),
            "ReadFile": ([w.HANDLE, pointer, w.DWORD, c.POINTER(w.DWORD), pointer], w.BOOL),
            "WriteFile": ([w.HANDLE, pointer, w.DWORD, c.POINTER(w.DWORD), pointer], w.BOOL),
            "WaitForSingleObject": ([w.HANDLE, w.DWORD], w.DWORD),
            "GetExitCodeProcess": ([w.HANDLE, c.POINTER(w.DWORD)], w.BOOL),
            "TerminateProcess": ([w.HANDLE, w.UINT], w.BOOL),
            "OpenThread": ([w.DWORD, w.BOOL, w.DWORD], w.HANDLE),
            "CancelSynchronousIo": ([w.HANDLE], w.BOOL),
        }
        for name, (args, result) in prototypes.items():
            function = getattr(api, name)
            function.argtypes = args
            function.restype = result
        self.output = bytearray()
        self.input = w.HANDLE()
        self.read = w.HANDLE()
        self.console = w.HANDLE()
        self.process = ProcessInfo()
        self.reader = None
        self.attributes = None
        self.attributes_ready = False
        child_in, child_out = w.HANDLE(), w.HANDLE()
        try:
            self.check(api.CreatePipe(c.byref(child_in), c.byref(self.input), None, 0))
            self.check(api.CreatePipe(c.byref(self.read), c.byref(child_out), None, 0))
            result = api.CreatePseudoConsole(Coord(80, 24), child_in, child_out, 0, c.byref(self.console))
            if result < 0:
                raise OSError(f"CreatePseudoConsole HRESULT {result:#x}")
            required = c.c_size_t()
            api.InitializeProcThreadAttributeList(None, 1, 0, c.byref(required))
            self.attributes = c.create_string_buffer(required.value)
            self.check(api.InitializeProcThreadAttributeList(self.attributes, 1, 0, c.byref(required)))
            self.attributes_ready = True
            self.check(api.UpdateProcThreadAttribute(self.attributes, 0, 0x20016, self.console,
                                                    c.sizeof(w.HANDLE), None, None))
            startup = StartupEx()
            startup.startup.cb = c.sizeof(StartupEx)
            # Explicit null standard handles let ConPTY supply its console handles.
            # Otherwise Windows duplicates the CI runner's redirected pipes:
            # https://github.com/microsoft/terminal/discussions/15814
            startup.startup.flags = 0x100  # STARTF_USESTDHANDLES
            startup.attributes = c.cast(self.attributes, pointer)
            command = c.create_unicode_buffer(subprocess.list2cmdline(argv))
            self.reader = threading.Thread(target=self._read, daemon=True)
            self.reader.start()
            self.check(api.CreateProcessW(None, command, None, None, False, 0x80000,
                                          None, None, c.byref(startup), c.byref(self.process)))
        except BaseException:
            self.close()
            raise
        finally:
            for handle in (child_in, child_out):
                if handle:
                    api.CloseHandle(handle)

    @staticmethod
    def check(success):
        if not success:
            raise c.WinError(c.get_last_error())

    def _read(self):
        buffer = c.create_string_buffer(65536)
        count = w.DWORD()
        while self.api.ReadFile(self.read, buffer, len(buffer), c.byref(count), None) and count.value:
            self.output.extend(buffer.raw[:count.value])

    def write(self, data: bytes):
        count = w.DWORD()
        self.check(self.api.WriteFile(self.input, data, len(data), c.byref(count), None))
        if count.value != len(data):
            raise OSError("short ConPTY input write")

    def resize(self):
        result = self.api.ResizePseudoConsole(self.console, Coord(100, 30))
        if result < 0:
            raise OSError(f"ResizePseudoConsole HRESULT {result:#x}")

    def wait_for(self, marker: bytes, timeout: float = 10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if marker in self.output:
                return
            if self.api.WaitForSingleObject(self.process.process, 10) == 0:
                break
        raise AssertionError(f"ConPTY did not produce {marker!r}: {bytes(self.output[-2000:])!r}")

    def wait(self, timeout: float = 3):
        if self.api.WaitForSingleObject(self.process.process, int(timeout * 1000)) != 0:
            raise TimeoutError("native session did not exit")
        code = w.DWORD()
        self.check(self.api.GetExitCodeProcess(self.process.process, c.byref(code)))
        return code.value

    def close(self):
        if self.process.process and self.api.WaitForSingleObject(self.process.process, 0) != 0:
            self.api.TerminateProcess(self.process.process, 1)
            self.api.WaitForSingleObject(self.process.process, 2000)
        if self.console:
            self.api.ClosePseudoConsole(self.console)
            self.console = w.HANDLE()
        if self.reader is not None:
            self.reader.join(1)
            if self.reader.is_alive():
                thread = self.api.OpenThread(1, False, self.reader.native_id)
                if thread:
                    self.api.CancelSynchronousIo(thread)
                    self.api.CloseHandle(thread)
                self.reader.join(1)
        if self.attributes_ready:
            self.api.DeleteProcThreadAttributeList(self.attributes)
            self.attributes = None
        for handle in (self.process.thread, self.process.process, self.input, self.read):
            if handle:
                self.api.CloseHandle(handle)
