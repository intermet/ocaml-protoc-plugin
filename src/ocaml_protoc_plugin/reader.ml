(** Some buffer to hold data, and to read and write data *)
open StdLabels

type t = {
  mutable offset : int;
  end_offset : int;
  data : String.t;
}

let create ?(offset = 0) ?length data =
  let end_offset =
    match length with
    | None -> String.length data
    | Some l -> offset + l
  in
  assert (end_offset >= offset);
  assert (String.length data >= end_offset);
  {offset; end_offset; data}

let reset t offset = t.offset <- offset
let offset { offset; _ } = offset

let[@inline] validate_capacity t count =
  match t.offset + count <= t.end_offset with
  | true -> ()
  | false ->
    Result.raise `Premature_end_of_input

let[@inline] has_more t = t.offset < t.end_offset

let[@inline] read_byte t =
  match t.offset < t.end_offset with
  | true ->
    let v = String.unsafe_get t.data t.offset |> Char.code in
    t.offset <- t.offset + 1;
    v
  | false -> Result.raise `Premature_end_of_input

let read_varint t =
  let open Infix.Int64 in
  let rec inner acc bit =
    let v = read_byte t |> Int64.of_int in
    let acc = acc lor ((v land 0x7fL) lsl bit) in
    match v land 0x80L = 0x80L with
    | true ->
      inner acc (Int.add bit 7)
    | false -> acc
  in
  inner 0L 0[@@unrolled 10]

let read_varint_unboxed t = read_varint t |> Int64.to_int

let read_fixed32 t =
  let size = 4 in
  validate_capacity t size;
  let v = Bytes.get_int32_le (Bytes.unsafe_of_string t.data) t.offset in
  t.offset <- t.offset + size;
  v

let read_fixed64 t =
  let size = 8 in
  validate_capacity t size;
  let v = Bytes.get_int64_le (Bytes.unsafe_of_string t.data) t.offset in
  t.offset <- t.offset + size;
  v

let read_length_delimited t =
  let length = read_varint_unboxed t in
  validate_capacity t length;
  let v = Field.{ offset = t.offset; length = length; data = t.data } in
  t.offset <- t.offset + length;
  v

let read_field_header: t -> Field.field_type * int = fun t ->
  let v = read_varint_unboxed t in
  let tpe : Field.field_type = match v land 0x7 with
    | 0 -> Varint
    | 1 -> Fixed64
    | 2 -> Length_delimited
    | 5 -> Fixed32
    | _ -> failwith (Printf.sprintf "Illegal field header: 0x%x" v)
  in
  let field_number = v / 8 in
  (tpe, field_number)

let read_field_content: Field.field_type -> t -> Field.t = function
  | Varint -> fun r -> Field.Varint (read_varint r)
  | Fixed64 -> fun r -> Field.Fixed_64_bit (read_fixed64 r)
  | Length_delimited -> fun r -> Length_delimited (read_length_delimited r)
  | Fixed32 -> fun r -> Field.Fixed_32_bit (read_fixed32 r)

let next_field_header reader =
  match has_more reader with
  | true -> Some (read_field_header reader)
  | false -> None

let to_list: t -> (int * Field.t) list =
  let read_field t =
    let (tpe, index) = read_field_header t in
    let field = read_field_content tpe t in
    (index, field)
  in
  let rec next t () = match has_more t with
    | true -> Seq.Cons (read_field t, next t)
    | false -> Seq.Nil
  in
  fun t ->
    next t |> List.of_seq


let%expect_test "varint boxed" =
  let values = [-2L; -1L; 0x7FFFFFFFFFFFFFFFL; 0x7FFFFFFFFFFFFFFEL; 0x3FFFFFFFFFFFFFFFL; 0x3FFFFFFFFFFFFFFEL; 0L; 1L] in
  List.iter ~f:(fun v ->
    let buffer =
      let writer = Writer.init () in
      Writer.write_varint_value v writer;
      Writer.contents writer
    in
    Printf.printf "0x%016LxL = 0x%016LxL\n"
      v
      (read_varint (create buffer));
    ()
  ) values;
  [%expect {|
    0xfffffffffffffffeL = 0xfffffffffffffffeL
    0xffffffffffffffffL = 0xffffffffffffffffL
    0x7fffffffffffffffL = 0x7fffffffffffffffL
    0x7ffffffffffffffeL = 0x7ffffffffffffffeL
    0x3fffffffffffffffL = 0x3fffffffffffffffL
    0x3ffffffffffffffeL = 0x3ffffffffffffffeL
    0x0000000000000000L = 0x0000000000000000L
    0x0000000000000001L = 0x0000000000000001L |}]
