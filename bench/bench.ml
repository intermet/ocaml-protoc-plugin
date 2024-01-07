open Base
open Stdio
[@@@ocaml.warning "-32"]
module type Protoc_impl = sig
  type m
  val encode_pb_m: m -> Pbrt.Encoder.t -> unit
  val decode_pb_m: Pbrt.Decoder.t -> m
end

module type Plugin_impl = sig
  module M : sig
    type t
    val name' : unit -> string
    val show: t -> string
    val equal: t -> t -> bool
    val to_proto: t -> Ocaml_protoc_plugin.Writer.t
    val to_proto': Ocaml_protoc_plugin.Writer.t -> t -> Ocaml_protoc_plugin.Writer.t
    val from_proto_exn: Ocaml_protoc_plugin.Reader.t -> t
  end
end

let make_tests (type v) (module Protoc: Protoc_impl) (module Plugin: Plugin_impl with type M.t = v) v_plugin =

  (* Verify *)
  let verify_identity ~mode data =
    let writer = Plugin.M.to_proto' (Ocaml_protoc_plugin.Writer.init ~mode ()) data in
    let data' = Plugin.M.from_proto_exn (Ocaml_protoc_plugin.Reader.create (Ocaml_protoc_plugin.Writer.contents writer)) in
    let () = match Plugin.M.equal data data' with
      | true -> ()
      | false ->
        eprintf "Orig: %s\n" (Plugin.M.show data);
        eprintf "New: %s\n" (Plugin.M.show data');
        failwith "Data not the same"
    in
    Ocaml_protoc_plugin.Writer.contents writer |> String.length,
    Ocaml_protoc_plugin.Writer.unused_space writer
  in
  let size_normal, unused_normal = verify_identity ~mode:Ocaml_protoc_plugin.Writer.Balanced v_plugin in
  let size_speed, unused_speed = verify_identity ~mode:Ocaml_protoc_plugin.Writer.Speed v_plugin in
  let size_space, unused_space = verify_identity ~mode:Ocaml_protoc_plugin.Writer.Space v_plugin in
  let data = Plugin.M.to_proto' (Ocaml_protoc_plugin.Writer.init ()) v_plugin |> Ocaml_protoc_plugin.Writer.contents  in
  let v_plugin = Plugin.M.from_proto_exn (Ocaml_protoc_plugin.Reader.create data) in
  let v_protoc = Protoc.decode_pb_m (Pbrt.Decoder.of_string data) in
  let protoc_encoder = Pbrt.Encoder.create () in
  let () = Protoc.encode_pb_m v_protoc protoc_encoder in
  let data_protoc = Pbrt.Encoder.to_string protoc_encoder in
  let v_plugin' = Plugin.M.from_proto_exn (Ocaml_protoc_plugin.Reader.create data_protoc) in
  let () = match Plugin.M.equal v_plugin v_plugin' with
    | true -> ()
    | false ->
       eprintf "Orig: %s\n" (Plugin.M.show v_plugin);
       eprintf "New: %s\n" (Plugin.M.show v_plugin');
       failwith "Data not the same"
  in
  printf "%-16s: %5d+%-5d(B) / %5d+%-5d(S) / %5d+%-5d(Sp) - %5d\n%!" (Plugin.M.name' ())
    size_normal unused_normal size_speed unused_speed size_space unused_space (String.length data_protoc);


  let open Bechamel in
    let test_encode =
    Test.make_grouped ~name:"Encode"
      [
        Test.make ~name:"Plugin balanced" (Staged.stage @@ fun () -> Plugin.M.to_proto' Ocaml_protoc_plugin.Writer.(init ~mode:Balanced ()) v_plugin |> Ocaml_protoc_plugin.Writer.contents);
        Test.make ~name:"Plugin speed" (Staged.stage @@ fun () -> Plugin.M.to_proto' Ocaml_protoc_plugin.Writer.(init ~mode:Speed ()) v_plugin |> Ocaml_protoc_plugin.Writer.contents);
        Test.make ~name:"Plugin space" (Staged.stage @@ fun () -> Plugin.M.to_proto' Ocaml_protoc_plugin.Writer.(init ~mode:Space ()) v_plugin |> Ocaml_protoc_plugin.Writer.contents);
        Test.make ~name:"Protoc" (Staged.stage @@ fun () -> let encoder = Pbrt.Encoder.create () in Protoc.encode_pb_m v_protoc encoder; (Pbrt.Encoder.to_string encoder))
      ]
  in
  let test_decode =
    Test.make_grouped ~name:"Decode"
      [
        Test.make ~name:"Plugin" (Staged.stage @@ fun () -> Plugin.M.from_proto_exn (Ocaml_protoc_plugin.Reader.create data));
        Test.make ~name:"Protoc" (Staged.stage @@ fun () -> Protoc.decode_pb_m (Pbrt.Decoder.of_string data))
      ]
  in
  Test.make_grouped ~name:(Plugin.M.name' ()) [test_encode; test_decode]

let _ =
  Random.init 0;
  let module Gc = Stdlib.Gc in
  Gc.full_major ();
  let control = Gc.get () in
  Gc.set { control with minor_heap_size=4000_1000; space_overhead=500 }


let random_list ?(len=100) ~f () =
  List.init (Random.int len) ~f:(fun _ -> f ())

let random_string () =
  String.init (Random.int 20) ~f:(fun _ -> Random.char ())

let create_test_data ~depth () =
  let module M = Plugin.Bench.M in
  let module Data = Plugin.Bench.Data in
  let module Enum = Plugin.Bench.Enum in
  let optional ~f () =
    match (Random.int 4 = 0) with
    | true -> None
    | false -> Some (f ())
  in
  let create_data () =

    let random_enum () =
      Array.random_element_exn [| Enum.EA; Enum.EB; Enum.EC; Enum.ED; Enum.EE; |]
    in
    let s1 = optional ~f:random_string () in
    let n1 = optional ~f:(random_list ~f:(fun () -> Random.int 1_000)) () in
    let n2 = optional ~f:(random_list ~f:(fun () -> Random.int 1_000)) () in
    let d1 = optional ~f:(random_list ~f:(fun () -> Random.float 1_000.)) () in
    let n3 = optional ~f:(fun () -> Random.int 1_000) () in
    let b1 = optional ~f:Random.bool () in
    let _e = optional ~f:(random_list ~f:random_enum) () in

    Data.make ?s1 ?n1 ?n2 ?d1 ?n3 ?b1 (* ?e *) ()
  in

  let rec create_btree n () =
    match n with
    | 0 -> None
    | n ->
      let data = random_list ~f:create_data () in
      let children =
        random_list ~len:8 ~f:(create_btree (n - 1)) () |> List.filter_opt
      in
      M.make ~children ~data () |> Option.some
  in
  create_btree depth ()

let benchmark tests =
  let open Bechamel in
  let instances = Bechamel_perf.Instance.[ cpu_clock ] in
  let cfg = Benchmark.cfg ~limit:2000 ~quota:(Time.second 5.0) ~kde:(Some 1000) ~stabilize:true ~compaction:false () in
  Benchmark.all cfg instances tests

let analyze results =
  let open Bechamel in
  let ols = Analyze.ols ~bootstrap:10 ~r_square:false
    ~predictors:[| Measure.run |] in
  let results = Analyze.all ols Bechamel_perf.Instance.cpu_clock results in
  Analyze.merge ols [ Bechamel_perf.Instance.cpu_clock ] [ results ]

let print_bench_results results =
  let open Bechamel in
  let () = Bechamel_notty.Unit.add
             Bechamel_perf.Instance.cpu_clock
             (Measure.unit Bechamel_perf.Instance.cpu_clock)
  in

  let img (window, results) =
    Bechamel_notty.Multiple.image_of_ols_results ~rect:window
      ~predictor:Measure.run results
  in

  let open Notty_unix in

  let window =
    match winsize Unix.stdout with
    | Some (w, h) -> { Bechamel_notty.w; h }
    | None -> { Bechamel_notty.w= 80; h= 1; } in
  img (window, results) |> eol |> output_image


let _ =
  let v_plugin = create_test_data ~depth:2 () |> Option.value_exn in
  [ make_tests (module Protoc.Bench) (module Plugin.Bench) v_plugin;
    make_tests (module Protoc.Int64) (module Plugin.Int64) 27;
    make_tests (module Protoc.Float) (module Plugin.Float) 27.0001;
    make_tests (module Protoc.String) (module Plugin.String) "Benchmark";
    make_tests (module Protoc.Enum) (module Plugin.Enum) Plugin.Enum.Enum.ED;

    List.init 1000 ~f:(fun i -> i) |> make_tests (module Protoc.Int64_list) (module Plugin.Int64_list);
    List.init 1000 ~f:(fun i -> Float.of_int i) |> make_tests (module Protoc.Float_list) (module Plugin.Float_list);
    List.init 1000 ~f:(fun _ -> random_string ()) |> make_tests (module Protoc.String_list) (module Plugin.String_list);
    (* random_list ~len:100 ~f:(fun () -> Plugin.Enum_list.Enum.ED) () |> make_tests (module Protoc.Enum_list) (module Plugin.Enum_list); *)
  ]
  |> List.rev |> List.iter ~f:(fun test ->
    test
    |> benchmark
    |> analyze
    |> print_bench_results
  )
