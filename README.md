# is_web_request_driver

intersyntactic's web request driver: the service that `CarriesOutWebRequests` (from
[is_effects](https://github.com/intersyntactic/effects)), making each
`Request` under one of the person's sign-ins. A tool describes the request
and names a sign-in such as `cam-teams`, and the airlock decides on it. The
web request driver holds the secret and is the only piece that ever sees it.

It knows nothing about any destination. A sign-in's kind is a way of
proving who you are, such as OAuth 2 client credentials. Everything a
destination adds sits in that sign-in's file: where its token comes from,
which sites it's for, and which field of a reply names what was made. So
Teams, Slack or GitHub is a file, not a change to this package.

## What carrying out a web request does

1. **The path stays on its origin.** `path` is appended to `origin`, and the
   driver refuses anything that would name another site. For example,
   `@evil.example` after `https://a.example` reads as a login to
   `evil.example`.
2. **A sign-in goes only to its own sites.** The airlock decides by name
   alone, so it can't know that a sign-in next to an origin outside its file
   would hand a token to a stranger. Only the driver can, and it refuses that
   web request.
3. **The driver signs the request.** It does this the way the sign-in's kind
   says, and keeps any token until five minutes before it expires. Concurrent
   web requests share a single fetch.
4. **It reads what the destination made.** That becomes `WebResponse.created`: the
   field the sign-in names, taken from a 2xx JSON reply.

5. **It says why a destination refused.** A failure moves a piece of
   information of its own: why. A `400`'s body names the problem, and a
   refused token's names the cause (`AADSTS7000215` is a wrong secret).
   The logbook keeps what it's given for good, so it gets **a word, not the
   body**. `WebResponse.refusedBecause` is the one field the sign-in names as its
   reason, such as `error.code` → `ConversationNotFound`. A refused token's
   `Refused` reason carries OAuth's own `error` code, such as
   `invalid_client`. The whole body goes only to the driver's log, for
   whoever runs it. The service logs to stdout, which is the journal on the
   box, and bodies are clipped to 2,000 characters. A successful reply gets
   one line: method, site, sign-in, status and created id, never its path
   (which holds conversation ids) or body. A token service's 200 is never
   logged, since that body is the token.
6. **It keeps a body only when asked.** `Request.keep` says `none`, `text`
   or `bytes`, and only a 2xx body is kept. A body over `maxBodyBytes`
   (16 MiB unless the program sets it) is never read past the limit, and
   asking to keep one is `Refused`, as is asking for text that isn't UTF-8.
7. **It follows a redirect only where the sign-in goes.** Only a GET's
   redirect is followed, since a GET changes nothing; any other method gets
   the redirect as its answer. The next site must be one in the sign-in's
   file (with no sign-in, the site the request was decided for), there are
   at most three hops, and the sign-in's secret goes only to the site the
   request was decided for, never across a hop to another. Every hop is in
   `WebResponse.redirects` as its site and path, without the query, since
   a pre-authenticated download address carries its token there. Anything
   else is `Refused`, and nothing is sent to the site it pointed at.

`Ran(WebResponse)` means the request left the home and got a reply, whatever its
status. `Refused` means nothing reached the destination: an unknown sign-in,
a foreign origin or path, a token the sign-in service wouldn't issue, or a
network failure before any reply. The exceptions are a body that can't be
kept as asked and a GET's redirect that can't be followed: the site
answered, but nothing it answered is kept.

A `Refused` reason can leave the machine, shown to the person who asked, so
it names a site but never an address's query or anything the site sent: a
network failure gives its site and what failed (`Connection closed before
full header was received`), not the address it failed at.

## Sign-ins

`Credential.load(directory)` reads every file in `directory`, one per
sign-in, each named for its sign-in. That is the layout systemd's
`LoadCredential=` produces in `$CREDENTIALS_DIRECTORY`, where only the
service's user can read the files. The program that runs the driver passes
in that directory. This package never reads the environment.

| kind | signs with | fields |
|---|---|---|
| `client-credentials` | an OAuth 2 bearer token from `tokenUrl` (https only) | `tokenUrl`, `clientId`, `secret`, optional `scope` |

Every kind also takes `origins`, the only sites the sign-in is ever shown
to, and two optional reply fields, each a path of keys such as `error.code`:
`created`, naming what a 2xx reply made, and `refusedBecause`, naming why a
non-2xx reply refused.

For example, `cam-teams` is a Teams bot. Its `created` is the new activity's
id, which a card press names later. Its `refusedBecause` is the Bot
Framework error's code:

```json
{
  "kind": "client-credentials",
  "tokenUrl": "https://login.microsoftonline.com/<tenant>/oauth2/v2.0/token",
  "clientId": "<app id>",
  "secret": "<app secret>",
  "scope": "https://api.botframework.com/.default",
  "origins": ["https://smba.trafficmanager.net"],
  "created": "id",
  "refusedBecause": "error.code"
}
```

## Running as its own service

Each driver is a wall of its own
([RULINGS](https://github.com/enspyrco/intersyntactic/blob/main/RULINGS.md)).
It runs as its own OS user, holds only its own secrets, and answers only
the airlock's user. So the driver runs as a service:

```
WEB_REQUEST_DRIVER_SOCKET=/run/intersyntactic-web-driver/web-driver.sock \
  WEB_REQUEST_DRIVER_CALLER=<the airlock's user> \
  dart run is_web_request_driver:service      # CREDENTIALS_DIRECTORY from LoadCredential=
```

The service reads who is calling from the socket, as the kernel reports it
(`SO_PEERCRED`), through is_unix_socket_user_check, which every
intersyntactic service shares. It answers no one else: a connection from
any other user, or one whose user the kernel can't name, is closed
unanswered, and no web request is made. The caller is a `UserId`, which
can't be `nobody` or the overflow uid 65534, so the service won't start
configured for one. A caller writes one request per connection and closes
its side. The service answers one line and closes. Both are is_effects' own JSON
(`encodeRequest`, `encodeOutcome` with `encodeWebResponse`), shared
with the airlock, so neither side keeps a codec of its own:

```
→ {"origin":"https://…","method":"post","path":"/…","signIn":"cam-teams","headers":{…},"body":"…"}
← {"kind":"ran","output":{"status":201,"created":"…","refusedBecause":null}}
← {"kind":"refused","why":"…"}
```

A web request that got a 4xx reply still `ran`. A path that would name
another site can't be built as a `WebPath`, and the socket refuses one
arriving as text before anything is made. The airlock side is `WebRequestDriverSocket` from
`package:is_web_request_driver/service.dart`. It `CarriesOutWebRequests` and holds no secret, so the airlock
holds it as it would any other way of carrying out web requests. Its
optional `checkDriver` looks at the connected driver before the request is
written, such as which release the kernel says it is, and a reason it
returns refuses the request unsent. Each
sign-in is its own file, so a sign-in that needs a wall of its own can run
as a second instance of this service with only that file.
