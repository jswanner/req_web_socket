# CHANGELOG

## Unreleased

  * Support Req >= 0.8.0-rc.0 (drop support for < 0.8)

### Breaking Changes

  * When using `into: fun`, removed support for return value to include frames
    for ReqWebSocket to send, explicitly send frames in body of function.
  * Removed `ReqWebSocket.parse_message` use `Req.parse_message` instead, this
    needed when using `into: :self.

### Deprecations

  * Deprecate `into: fun`, as Req has deprecated it in favor of `Req.stream/4`

## v0.2.0 (2026-07-29)

  * Resolve deprecation for Req >= 0.7 (drop support for < 0.7)

## v0.1.2 (2026-06-16)

  * Bump req requirement to allow ~> 0.6.0

## v0.1.1 (2026-04-03)

  * Ensures unrelated messages are not unintentionally intercepted (applicable
  to `into: :self`).

## v0.1.0 (2025-10-10)

  * Initial release.
