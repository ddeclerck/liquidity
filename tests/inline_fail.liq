type storage = unit

let[@inline] f x = failwith x

let%entry main () s =
  f 1;
  let _x = f 0 in
  [], s
