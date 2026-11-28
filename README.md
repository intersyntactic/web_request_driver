# is_web_request_driver

intersyntactic's web request driver: the service behind the airlock's
`CarriesOutWebRequests` (from
[is_effects](https://github.com/intersyntactic/effects)), making each
`GrantedRequest` under one of its named sign-ins, each an identity of its own.
A tool describes the request and names a sign-in, and the airlock decides on
it. The web request driver holds the secret and is the only piece that ever
sees it.

It knows nothing about any destination. A sign-in's kind is a way of
proving who you are. Everything a destination adds sits in that sign-in's
file: where its token comes from, which sites it's for, and which field of a
reply names what was made. So a new destination is a new file.

## What carrying out a web request does

1. **The path stays on its origin.** `path` is appended to `origin`, and the
   driver refuses anything that would name another site.
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
   information of its own: why. The logbook keeps what it's given for good,
   so it gets **one word**. `WebResponse.refusedBecause` is the one field the
   sign-in names as its reason. A refused token's `NothingRan` reason
   carries OAuth's own `error` code. The whole body goes only to the
   driver's log, for whoever runs it. The service logs to stdout, which is
   the journal on the box, and bodies are clipped to 2,000 characters. A
   successful reply gets one line: method, site, sign-in, status and created
   id, never its path or body. A token service's 200 is never logged, since
   that body is the token.
6. **It keeps a body only when asked.** `ProposedRequest.keep` says `none`, `text`
   or `bytes`, and only a 2xx body is kept. A body over `maxBodyBytes`
   (16 MiB unless the program sets it) is never read past the limit, and
   asking to keep one is `StoppedPartway`, as is asking for text that isn't
   UTF-8.
7. **It follows a redirect only where the sign-in goes.** Only a GET's
   redirect is followed, since a GET changes nothing; any other method gets
   the redirect as its answer. The next site must be one in the sign-in's
   file (with no sign-in, the site the request was decided for), there are
   at most three hops, and the sign-in's secret goes only to the site the
   request was decided for, never across a hop to another. A hop on the
   request's own site must stay under the path prefix its rule granted,
   `GrantedRequest.grantedPathPrefix`; a rule for a whole site grants `/`,
   which covers every path on it. Every hop is in
   `WebResponse.redirects` as its site and path, without the query, since
   a pre-authenticated download address carries its token there. Anything
   else is `StoppedPartway`, and nothing is sent to the site it pointed at.

`Ran(WebResponse)` means the request left the home and got a reply, whatever its
status. Anything else splits on whether the request was sent:

- `NothingRan` means it never left the driver: an unknown sign-in, a
  foreign origin or path, or a token the sign-in service wouldn't issue. It
  is safe to retry.
- `StoppedPartway` means it was sent and stopped before a reply could be
  kept: the connection dropped or timed out, a GET's redirect couldn't be
  followed, or the body couldn't be kept as asked. It is never safe to
  retry, since a POST may already have done its work. `done` is the last
  answer that arrived (its status and created id, without a body), or
  null when none did.

A reason can leave the machine, shown to the person who asked, so
it names a site but never an address's query or anything the site sent: a
network failure gives its site and what failed.

## Sign-ins

`Credential.load(directory)` reads every file in `directory`, one per
sign-in, each named for its sign-in. That is the layout systemd's
`LoadCredential=` produces in `$CREDENTIALS_DIRECTORY`, where only the
service's user can read the files. The program that runs the driver passes
in that directory. This package never reads the environment.

| kind | signs with | fields |
|---|---|---|
| `client-credentials` | an OAuth 2 bearer token from `tokenUrl` (https only) | `tokenUrl`, `clientId`, `secret`, optional `scope` |
| `bearer-token` | the bearer token it holds, issued ahead of time and never refreshed | `token` |

Every kind also takes `origins`, the only sites the sign-in is ever shown
to, and two optional reply fields, each a dotted path of keys where a number
indexes a list: `created`, naming what a 2xx reply made, and
`refusedBecause`, naming why a non-2xx reply refused. Either reads text, or a
whole number as its digits.

A kind may also take `pathPrefixes`, an object from some of its `origins`
to the path prefixes it reaches there. A request, and every redirect, to a
site listed there must be under one of them; a site not listed is bounded
only by `origins`. A prefix ends in `/` and covers only longer paths. This
bounds a broad token in the one place that holds it, whatever the request
was granted.

A `client-credentials` file, with every field:

```json
{
  "kind": "client-credentials",
  "tokenUrl": "https://<token service>/…",
  "clientId": "<client id>",
  "secret": "<secret>",
  "scope": "<scope>",
  "origins": ["https://<site>"],
  "pathPrefixes": {"https://<site>": ["/<prefix>/"]},
  "created": "<path of keys>",
  "refusedBecause": "<path of keys>"
}
```

A `bearer-token` file has `"token"` in place of `tokenUrl`, `clientId`,
`secret` and `scope`.

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
(`encodeGrantedRequest`, `encodeOutcome` with `encodeWebResponse`), shared
with the airlock, so neither side keeps a codec of its own. A request
with no `grantedPathPrefix`, or one that doesn't cover its path, is
`nothingRan`:

```
→ {"origin":"https://…","method":"post","path":"/…","grantedPathPrefix":"/…/","signIn":"…","headers":{…},"body":"…"}
← {"kind":"ran","output":{"status":201,"created":"…","refusedBecause":null}}
← {"kind":"nothingRan","why":"…"}
← {"kind":"stoppedPartway","why":"…","done":{"status":201,…}}
```

A web request that got a 4xx reply still `ran`. A path that would name
another site can't be built as a `WebPath`, and the socket refuses one
arriving as text before anything is made. `WebRequestDriver.start` is
the service: it binds the socket and serves it until `close`. The airlock
holds its own client of the socket, written over is_effects' wire codec,
so it depends on nothing in this package. Each
sign-in is its own file, so a sign-in that needs a wall of its own can run
as a second instance of this service with only that file.
