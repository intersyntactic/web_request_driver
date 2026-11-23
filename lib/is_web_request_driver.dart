/// Carries out web requests under the person's sign-ins. Holds each
/// sign-in's secret and applies it, so neither a tool nor the logbook ever sees
/// one.
library;

export 'package:is_unix_socket_user_check/is_unix_socket_user_check.dart'
    show UserId;

export 'src/credential.dart'
    show BearerToken, ClientCredentials, Credential, ReplyField;
export 'src/web_request_driver.dart';
export 'src/web_request_driver_socket.dart';
