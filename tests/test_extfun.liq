
[%%version 0.5]

let f (x, _) = x

type storage = unit

let%entry main
      (parameter : int)
      storage =
  let storage = f (storage, parameter) in
  ( [], storage )
