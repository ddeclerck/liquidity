[%%version 0.5]

type storage = { q : nat; res : (tez * tez) option * (nat * tez) option }

let%entry main
    (parameter : tez)
    storage =

  let e1 = parameter / storage.q in
  let e2 = parameter / parameter in
  let storage = storage.res <- (e1, e2) in
  [], storage
