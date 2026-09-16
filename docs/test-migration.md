# Behavioral test migration ledger

Reference: commit `3a6e421de5101973852e8735a202dcc1a5c6288a`. Tests are grouped
by observable contract in Zig; test counts are not expected to match one for one.
The installer tests remain as dependency-free native installer checks.

Platform binding details change intentionally: ApplicationServices replaces PyObjC
trust lookup, native XGetImage replaces Pillow fallback, and bounded poll readers
replace Python stderr-drain threads. Their externally visible failure, pixel,
ownership, and timeout contracts are covered by the native equivalents.
Python packaging compatibility checks are replaced by pinned Zig build/license checks.
Removed network integration is tested only for unknown-option rejection.

## test_agent.py

`native/agent.zig`, `native/cli.zig`, `native/routing.zig`; native command/SSH/Wayland fixtures

Migrated reference cases:

- `test_observe_and_computer_use_actions`
- `test_agent_rejects_untrusted_shell_commands`
- `test_portable_forced_command_routes_only_agent_grammar`
- `test_portable_forced_command_opens_shell_selector`
- `test_login_shell_arguments_match_each_platform`
- `test_windows_shell_selector_execs_without_login_flag`
- `test_portable_forced_command_requires_pty_for_shell_selector`
- `test_portable_forced_command_keeps_agent_commands_restricted`
- `test_portable_forced_command_accepts_explicit_desktop_command`
- `test_actions_are_bounded`
- `test_ydotool_adds_shift_for_uppercase`
- `test_ydotool_checks_daemon_without_injecting_input`
- `test_platform_selects_x11_and_wayland`
- `test_split_command_is_an_argument_vector`
- `test_remote_request_uses_only_fixed_ssh_command`
- `test_remote_request_timeout_is_configurable`
- `test_remote_reports_timeout_expiry_without_traceback`
- `test_remote_rejects_non_positive_timeout`

## test_agent_session.py

`native/agent.zig`; bounded JSON and signal integration tests

Migrated reference cases:

- `test_info_and_quit_stop_the_session`
- `test_errors_keep_the_session_alive`
- `test_oversized_requests_are_rejected_without_parsing`
- `test_keyboard_interrupt_during_startup_exits_cleanly`
- `test_keyboard_interrupt_from_session_exits_cleanly`

## test_capture.py

`native/platform/macos.zig`, `native/platform/gnome.zig`, `native/process.zig`; Xvfb and failed-FFmpeg integration

Migrated reference cases:

- `test_macos_quartz_capture_resizes_to_logical_pixels`
- `test_macos_quartz_capture_keeps_matching_logical_size`
- `test_macos_quartz_missing_frame_asks_for_screen_recording`
- `test_macos_grab_does_not_call_pillow_screencapture`
- `test_capture_helper_timeout_becomes_clean_runtime_error`
- `test_pillow_fallback_prescales_and_fingerprints_frame`
- `test_display_configuration_becomes_complete_desktop_area`
- `test_close_stops_screen_and_remote_desktop_sessions`
- `test_stderr_drain_keeps_tail_and_survives_closed_stream`
- `test_stderr_drain_ignores_read_errors`
- `test_capture_reports_drained_stderr_after_stream_ends`
- `test_set_frame_rate_bounds_are_enforced`

## test_input.py

`native/input.zig`, `native/render.zig`, `native/kitty.zig`, `native/platform/macos.zig`, `native/platform/gnome.zig`

Migrated reference cases:

- `test_process_is_trusted_uses_quartz_when_exported`
- `test_process_is_trusted_falls_back_to_application_services`
- `test_process_is_trusted_is_false_without_application_services`
- `test_key_mapping`
- `test_escape_alt_and_detach`
- `test_sgr_mouse`
- `test_consecutive_mouse_moves_are_coalesced_without_losing_clicks`
- `test_legacy_x10_mouse_fallback`
- `test_modified_navigation_keys`
- `test_cursor_report_is_consumed_as_latency_event`
- `test_oversized_terminal_sequence_is_rejected`
- `test_coordinate_translation_and_letterbox`
- `test_pixel_coordinate_translation_and_letterbox`
- `test_mutter_input_uses_linked_stream_and_bounds_pointer`

## test_lifecycle.py

native POSIX PTY integration (detach, signals, backpressure, Kitty); Windows ConPTY

Migrated reference cases:

- `test_terminal_restored_after_exception`
- `test_plain_pty_session_detaches_and_restores`
- `test_kitty_probe_selects_real_pixel_session`
- `test_server_rejects_non_pty_session_cleanly`

## test_performance.py

`native/session.zig`, `native/capabilities.zig`, `native/cli.zig`; Xvfb target/FPS propagation and failed-FFmpeg integration

Migrated reference cases:

- `test_frame_pump_keeps_latest_instead_of_queueing`
- `test_resize_discards_in_flight_old_geometry`
- `test_sharp_mode_defaults_to_60_fps_with_bounds`
- `test_render_scale_accepts_smooth_lower_resolution_mode`
- `test_auto_render_scale_tracks_client_backpressure`
- `test_terminal_backpressure_caps_refresh_rate`
- `test_pending_latency_probe_caps_refresh_rate`
- `test_identical_capture_digest_reuses_rendered_state`
- `test_frame_rate_change_reaches_capture_backend`
- `test_capture_worker_preserves_backend_error_detail`

## test_render.py

`native/render.zig`, `native/kitty.zig`, `native/capabilities.zig`; native ANSI/Kitty PTY fixtures

Migrated reference cases:

- `test_full_delta_and_unchanged`
- `test_large_change_becomes_full`
- `test_resize_forces_full`
- `test_aspect_ratio_letterboxes`
- `test_renderers_reserve_the_device_header_row`
- `test_device_header_and_terminal_title_are_restored`
- `test_delta_writer_emits_one_glyph_per_change`
- `test_color_fallbacks`
- `test_terminal_capability_detection`
- `test_kitty_probe_and_bounded_pixel_geometry`
- `test_kitty_renderer_uses_terminal_pixels_and_tile_deltas`
- `test_kitty_renderer_uses_client_fps_friendly_tile_count`
- `test_renderer_accepts_prescaled_frame_with_desktop_coordinates`
- `test_render_scale_reduces_capture_targets_without_changing_desktop_mapping`
- `test_kitty_renderer_never_upscales_the_remote_desktop`
- `test_kitty_writer_emits_chunked_paletted_png`
- `test_kitty_writer_uses_one_canvas_for_large_updates`
- `test_kitty_graphics_are_wrapped_for_tmux`
