# Revision history for `cryptol` Python package

## 2.11.5 -- 2021-08-25

* From argo: Change the behavior of the `Command` `state` method so that after
  a `Command` raises an exception, subsequent interactions will not also raise
  the same exception.

## 2.11.4 -- 2021-07-22

* Add client logging option. See the `log_dest` keyword argument on
  `cryptol.connect` or the `logging` method on a `CryptolConnection` object.

## 2.11.3 -- 2021-07-20

* Removed automatic reset from `CryptolConnection.__del__`.


## 2.11.2 -- 2021-06-23

* Ability to leverage HTTPS/TLS while _disabling_ verification of SSL certificates.
  See the `verify` keyword argument on `cryptol.connection.connect(...)`.
