type storage = {
  a : (string, int) big_map;
  b : unit;
}

let%init storage = {
  a = (BigMap [] : (string, int) big_map);
  b = ();
}

let%entry main (_parameter : unit) storage = 
  Current.failwith storage.b
