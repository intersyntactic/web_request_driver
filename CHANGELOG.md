# Changelog

## 0.11.1

- is_effects ^0.14.2, locked at 0.14.2, so a build of this driver
  resolves the same is_effects as the rest of the home. No change in
  behaviour.

## 0.11.0

- **Breaking:** is_effects ^0.14.0. The socket reads a `GrantedRequest`
  (`decodeGrantedRequest`), so a request must carry `grantedPathPrefix`
  covering its path, or it is refused before anything is sent. An
  airlock built before is_effects 0.14 sends none, so this driver must
  be deployed with or after an airlock that does.
- A redirect on the request's own site is checked against its grant on
  every request, since every grant now has a prefix; a grant of a whole
  site is `/`, which covers every path on it.

## 0.10.0

- **Breaking:** `WebRequestDriver` is the service, in one class:
  `WebRequestDriver.start(signIns, caller:, socket:, http:, now:, log:,
  maxBodyBytes:)` binds the socket and serves it until `close()`.
  `WebRequestDriverService` is gone, and `WebRequestDriver` no longer
  `CarriesOutWebRequests` in-process.
- **Breaking:** `package:is_web_request_driver/service.dart` is gone, with
  `WebRequestDriverSocket` and `CheckDriver`. A caller holds its own client
  over is_effects' wire codec, so nothing outside this package depends on
  its code. `UserId` comes from the main library.
- The socket's protocol, and how the driver signs, redirects and refuses,
  are unchanged.

## 0.9.0

- **Breaking:** a second kind, `bearer-token` (`BearerToken`): a token
  issued ahead of time, such as a Meta system user's, sent as
  `Authorization: Bearer` and never fetched or refreshed. A `switch` over
  `Credential` needs its case.
- `pathPrefixes`, optional on every kind: for each site it lists, the
  only path prefixes the sign-in reaches there. A request or redirect
  outside them is refused and never sent.
- A reply field path's numeric key indexes a JSON list (`messages.0.id`),
  and a whole number reads as its digits (Meta's `error.code` is 190).

## 0.8.0

- **Breaking:** is_effects ^0.13.0.
- A redirect that stays on the request's own site must stay under
  `Request.grantedPathPrefix`, when it has one. A hop that leaves it, or
  whose path `WebPath.parse` refuses (such as `%252e`, which a server could
  decode twice into `..`), is refused and not followed. The refusal names
  the site and the prefix, never the hop's path or query. A redirect to
  another site still goes only where the sign-in is for.

## 0.7.0

- The service checks its caller through is_unix_socket_user_check instead
  of its own copy of the socket's user read. A connection whose user can't
  be read is refused, as before.
- **Breaking:** `WebRequestDriverService.start` takes the caller as a
  `UserId` (exported from `service.dart`), not an `int`. `UserId.parse`
  refuses 65534, 4294967294 and 4294967295, so the service can't be
  configured to let in `nobody` or an unmapped user; the service binary
  exits 78 on one.

## 0.6.2

- A 2xx reply logs one line: `POST https://api.example as some-bot 201
  created 1`. Method, site, sign-in, status and created id; never the path
  or the body. A request sent straight to the socket, not through the
  airlock, used to leave no trace when it succeeded.

## 0.6.1

- A network failure's `Refused` reason no longer names the address it
  failed at. Dart's `HttpException` prints its uri with the query, so a
  connection dropped after a redirect put a pre-authenticated download's
  token into the reason. It now gives the site and the failure's message;
  the log gets the hop without its query. The same holds for a token
  request that fails, and for a path that would leave its origin.

## 0.6.0

- is_effects ^0.12.0. The web request wire is unchanged from 0.11.
- A `TextBody` keeps a leading byte order mark (U+FEFF), as is_effects
  0.11.1 asks. `utf8.decode` drops it, so 0.5.0 returned the text without
  it.

## 0.5.0

- is_effects ^0.11.0. A 2xx response's body comes back as `Request.keep`
  asks: `NoBody`, `TextBody` or `BytesBody`. `maxBodyBytes` (16 MiB by
  default) caps what is read; keeping a body over it is `Refused`, as is
  keeping text that isn't UTF-8.
- A GET's redirect is followed, only to a site in the sign-in's file (or,
  with no sign-in, the site decided), for at most three hops, and every hop
  is named in `WebResponse.redirects` without its query. The sign-in's
  secret goes only to the site decided, never across a hop. Any other
  redirect is `Refused`; a non-GET still gets its redirect as the answer.
- **Breaking:** `HttpCall` takes a fifth argument, the most body bytes to
  read, and `HttpResult` is `({int status, Uint8List? body, Uri? location})`:
  the body as bytes, null when over that limit.

## 0.4.2

- `httpCall` no longer follows redirects. A 3xx comes back as the response's
  status, so a request goes only to the site it was decided for, and the
  logbook shows where it went. `dart:io` followed GET and HEAD redirects, and
  a POST's 303, to any site, up to five hops, and the logbook never showed it.

## 0.4.1

- `WebRequestDriverSocket(socket, checkDriver:)`: an optional `CheckDriver`
  that runs on each connected socket before the request is written. A
  reason it returns becomes `Refused` and the driver never sees the request.
  The airlock uses it to check which release the kernel says the driver is.

## 0.4.0

- Renamed from `is_web_driver`: the package is `is_web_request_driver`, and
  `WebDriver`, `WebDriverService` and `WebDriverSocket` are
  `WebRequestDriver`, `WebRequestDriverService` and `WebRequestDriverSocket`.
  `WebDriver` is already the W3C name for browser automation. The service
  reads `WEB_REQUEST_DRIVER_SOCKET` and `WEB_REQUEST_DRIVER_CALLER` in place
  of `WEB_DRIVER_SOCKET` and `WEB_DRIVER_CALLER`.
- is_effects ^0.9.0: `carryOutWebRequest` returns `Outcome<WebResponse>`
  (formerly `WebRequestOutcome`), and the socket uses `encodeWebResponse` and
  `decodeWebResponse`. The JSON is unchanged, so a 0.3.0 driver and a 0.4.0
  airlock still understand each other.

## 0.3.0

- is_effects ^0.8.0. The API is unchanged, but it takes and returns
  is_effects types, so it can't share a project with is_effects 0.7. The
  socket's JSON is byte for byte the same, so a 0.2.0 driver and a 0.3.0
  airlock still understand each other.

## 0.2.0

- One web driver and its socket: `SigningWebDriver` is `WebDriver`, the web
  driver itself, holding the secrets; `SocketWebDriver` is `WebDriverSocket`,
  the airlock's side of the web driver's socket. The old names said there
  were two kinds of web driver.
- is_effects 0.7.0: `CarriesOutWebRequests.carryOutWebRequest` returning
  `WebRequestOutcome` (formerly `WebDriver.send` and `Sent`, retired by name), and
  `Request.path` a `WebPath`, which cannot name another site.
- The driver as its own service (`dart run is_web_driver:service`), which
  answers only the airlock's user, as the kernel reports it for the socket.
  Each driver is a wall of its own.
- `WebDriverSocket` in `package:is_web_driver/service.dart`: the airlock's
  side, which `CarriesOutWebRequests` and holds no secret.
- Why a destination refused reaches the airlock as a word, not a body, since
  the logbook keeps it for good. `WebRequestOutcome.refusedBecause` is
  the reply field the sign-in's file names in `refusedBecause`, such as
  `error.code`. A refused token's `Refused` reason carries OAuth's `error`
  code. The whole body is only logged, for whoever runs the driver
  (`WebDriver(log:)`; the service logs to stdout).
- `created` and `refusedBecause` are `ReplyField`s, paths of keys into a JSON
  reply, checked when the sign-in's file loads.
- The socket speaks is_effects' own JSON for `Request` and
  `Outcome<WebRequestOutcome>`, shared with the airlock, in place of this
  package's own codec. An answer it can't read is `Refused`, never guessed at.

## 0.1.0

- First release: `SigningWebDriver`, the `WebDriver` from `is_effects` that
  holds each sign-in's secret. It signs only for the origins a sign-in's file
  lists, refuses paths that would leave their origin, and fills
  `Sent.created` from the reply field the sign-in names.
- `Credential` and its first kind, `ClientCredentials` (OAuth 2), loaded one
  file per sign-in from systemd's `$CREDENTIALS_DIRECTORY`.
