open StdLabels
open MoreLabels
open Spec.Descriptor.Google.Protobuf

type element =
  | Message | Field
  | Enum | Enum_value
  | Oneof
  | Service | Method
  | Extension
  | File
  | Option
  | Unknown of element * int

let rec string_of_element = function
  | Message -> "Message"
  | Field -> "Field"
  | Enum -> "Enum"
  | Enum_value -> "Enum_value"
  | Oneof -> "Oneof"
  | Service -> "Service"
  | Method -> "Method"
  | Extension -> "Extension"
  | File -> "File"
  | Option -> "Option"
  | Unknown (ctx, n) -> Printf.sprintf "Unknown(%s, %d)" (string_of_element ctx) n

let element_of_int ~context = function
  | 4 when context = File -> Message
  | 8 when context = File -> Option
  | 3 when context = Message -> Message

  | 5 when context = File -> Enum
  | 4 when context = Message -> Enum
  | 2 when context = Enum -> Enum_value

  | 8 when context = Message -> Oneof
  | 2 when context = Message -> Field

  | 6 when context = File -> Service
  | 2 when context = Service -> Method

  | 7 when context = File -> Extension
  | 6 when context = Message -> Extension

  | n -> Unknown (context, n)

type path = (element * int) list

let string_of_path path =
  List.map ~f:(fun (e, i) ->
    let e_str = string_of_element e in
    Printf.sprintf "(%s, %d)" e_str i
  ) path
  |> String.concat ~sep:"; "
  |> Printf.sprintf "[ %s ]"


type comment = string option
type comments = { leading: comment; trailing: comment; detatched: string list }

module Code_info_map = Map.Make(struct type t = path let compare = compare end)
type code_info_map = comments Code_info_map.t

type t = comments Utils.StringMap.t

let make_code_info_map: SourceCodeInfo.t option -> code_info_map = fun source_code_info ->
  let source_code_info = Option.value ~default:[] source_code_info in

  let rec map_location ~context = function
    | field_id :: number :: rest ->
      let element = element_of_int ~context field_id in
      (element, number) :: map_location ~context:element rest
    | [ field_id ] -> [ Field, field_id ]
    | [] -> []
  in

  let map =
    List.fold_left ~init:Code_info_map.empty ~f:(fun db location ->
      match location with
      | SourceCodeInfo.Location.{ leading_comments = None; trailing_comments = None; leading_detached_comments = []; _ } -> db
      | SourceCodeInfo.Location.{ leading_comments = leading; trailing_comments = trailing; leading_detached_comments = detatched; _ } ->
        let path = map_location ~context:File location.SourceCodeInfo.Location.path in
        let element = { leading; trailing; detatched } in
        Code_info_map.add ~key:path ~data:element db
    ) source_code_info
  in
  map

let concat_mapi ~f lst =
  let vs = List.mapi ~f lst in
  List.concat vs

let prepend_path ~tpe ~index ~name lst =
  let path = tpe, index in
  (path :: [], name) :: List.map ~f:(fun (p, n) ->
    path :: p, Printf.sprintf "%s.%s" name n
  ) lst

let traverse_field index FieldDescriptorProto.{ name; _ } =
  let name = Option.value_exn name in
  [Field, index], name

let traverse_extension index FieldDescriptorProto.{ name; _ } =
  let name = Option.value_exn name in
  [Extension, index], name

let traverse_service_method index MethodDescriptorProto.{ name; _ } =
  let name = Option.value_exn name in
  [Method, index], name

let traverse_service index ServiceDescriptorProto.{ name; method'; _ } =
  let name = Option.value_exn name in
  let values = List.mapi ~f:traverse_service_method method' in
  prepend_path ~tpe:Enum ~index ~name values

let traverse_enum_value index EnumValueDescriptorProto.{ name; _ } =
  let name = Option.value_exn name in
  [Enum_value, index], name

let traverse_enum_type index EnumDescriptorProto.{ name; value; _ } =
  let name = Option.value_exn name in
  let values = List.mapi ~f:traverse_enum_value value in
  prepend_path ~tpe:Enum ~index ~name values

let rec traverse_message index DescriptorProto.{ name; field; nested_type; enum_type; extension; _ } =
  let name = Option.value_exn name in
  let fields = List.mapi ~f:traverse_field field in
  let sub_messages = concat_mapi ~f:traverse_message nested_type in
  let extensions = List.mapi ~f:traverse_extension extension in
  let enums = concat_mapi ~f:traverse_enum_type enum_type in

  (fields @ sub_messages @ extensions @ enums)
  |> prepend_path ~tpe:Message ~index ~name

let traverse FileDescriptorProto.{ package; enum_type; service; extension; message_type; _ } =
  let package = match package with
    | Some package -> Printf.sprintf ".%s" package
    | None -> ""
  in
  let enums = concat_mapi ~f:traverse_enum_type enum_type in
  let services = concat_mapi ~f:traverse_service service in
  let messages = concat_mapi ~f:traverse_message message_type in
  let extensions = List.mapi ~f:traverse_extension extension in
  (enums @ services @ messages @ extensions )
  |> List.map ~f:(fun (path, name) -> path, Printf.sprintf "%s.%s" package name)


(** Traverse the full filedescriptor proto to construct proto_name -> comments mapping *)
let make: FileDescriptorProto.t -> t = fun filedescriptor ->
  let code_info_map = make_code_info_map filedescriptor.source_code_info in
  traverse filedescriptor
  |> List.fold_left ~init:Utils.StringMap.empty ~f:(fun t (path, name) ->
    match Code_info_map.find_opt path code_info_map with
    | Some comments -> Utils.StringMap.add ~key:name ~data:comments t
    | None -> t
  )