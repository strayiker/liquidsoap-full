(*****************************************************************************

  Liquidsoap, a programmable audio stream generator.
  Copyright 2003-2010 Savonet team

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details, fully stated in the COPYING
  file at the root of the liquidsoap distribution.

  You should have received a copy of the GNU General Public License
  along with this program; if not, write to the Free Software
  Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

 *****************************************************************************)

(** Decode and read metadatas of AAC files. *)

open Dtools

(* A custom input function take takes 
 * an offset into account *)
let offset_input input buf offset = 
  let len = String.length buf in
  (* If the buff is less than the offset,
   * consume the remaining data. *)
  let ret = 
    if len < offset then
      let rec cons len = 
        if len < offset then
          let (_,read) = input (offset - len) in
           cons (len+read)
      in
      cons len ;
      ref ""
    else
    (* If the buffer is more than the offset,
     * retain it and consume it first later. *)
      ref (String.sub buf offset (len-offset))
  in
  let input len =
    let first,fst_len = 
      let ret_len = String.length !ret in
      if ret_len > 0 then
       begin
        let fst_len = min len ret_len in
        let hd,tl = 
          String.sub !ret 0 fst_len,
          String.sub !ret fst_len (ret_len-fst_len)
        in
        ret := tl ;
        hd, fst_len
       end
      else
        "",0
    in
    if fst_len > 0 then
      let ret,len = 
        if len > fst_len then
          input (len-fst_len) 
        else
          "",0
      in
      Printf.sprintf "%s%s" first ret,(fst_len + len)
    else
      input len
  in
  input,ret

let log = Log.make ["decoder";"aac"]

module Make (Generator:Generator.S_Asio) =
struct

let create_decoder input =
  let resampler = Rutils.create_audio () in
  let dec = Faad.create () in
  let aacbuflen = 1024 in
  let (aacbuf,len) = input aacbuflen in
  let offset, sample_freq, chans =
     Faad.init dec aacbuf 0 len 
  in
  let input,ret = offset_input input aacbuf offset in
    Decoder.Decoder (fun gen ->
      let aacbuf,len = input aacbuflen in
      let pos, data = Faad.decode dec aacbuf 0 len in
      (* We need to keep the data 
       * that has not been decoded yet.. *)
      if pos < len then 
        ret := Printf.sprintf "%s%s" 
          !ret (String.sub aacbuf pos (len-pos)) ;
      let content,length =
        resampler ~audio_src_rate:(float sample_freq) data
      in
        Generator.set_mode gen `Audio ;
        Generator.put_audio gen content 0 (Array.length content.(0)))

end

module G = Generator.From_audio_video
module Buffered = Decoder.Buffered(G)
module Aac = Make(G)

let create_file_decoder filename kind =
  let generator = G.create `Audio in
    Buffered.file_decoder filename kind Aac.create_decoder generator

(* Get the number of channels of audio in an AAC file. *)
let get_type filename =
  let dec = Faad.create () in
  let fd = Unix.openfile filename [Unix.O_RDONLY] 0o644 in
  let aacbuflen = 1024 in
  let aacbuf = String.create aacbuflen in
    Tutils.finalize ~k:(fun () -> Unix.close fd)
      (fun () ->
         let _,rate,channels = 
           Faad.init dec aacbuf 0 (Unix.read fd aacbuf 0 aacbuflen)
         in
           log#f 4
             "Libfaad recognizes %S as AAC (%dHz,%d channels)."
             filename rate channels ;
           { Frame.
             audio = channels ;
             video = 0 ;
             midi  = 0 })

let () =
  Decoder.file_decoders#register
  "AAC/libfaad"
  ~sdoc:"Use libfaad to decode AAC if MIME type or file extension \
         is appropriate."
  (fun ~metadata filename kind ->
  let log = log#f 3 "%s" in
  (* Before doing anything, check that we are allowed to produce
   * audio, and don't have to produce midi or video. Only then
   * check that the file seems relevant for MP3 decoding. *)
  if kind.Frame.audio = Frame.Zero ||
     not (Frame.mul_sub_mul Frame.Zero kind.Frame.video &&
          Frame.mul_sub_mul Frame.Zero kind.Frame.midi) ||
     not (Decoder.test_aac ~log filename)
  then
    None
  else
    if kind.Frame.audio = Frame.Variable ||
       kind.Frame.audio = Frame.Succ Frame.Variable ||
       Frame.type_has_kind (get_type filename) kind
    then
      Some (fun () -> create_file_decoder filename kind)
    else
    None)

module D_stream = Make(Generator.From_audio_video_plus)

let () =
  Decoder.stream_decoders#register
    "AAC/libfaad"
    ~sdoc:"Use libfaad to decode any stream with an appropriate MIME type."
     (fun mime kind ->
        let (<:) a b = Frame.mul_sub_mul a b in
          if List.mem mime Decoder.aac_mime_types#get &&
             (* Check that it is okay to have zero video and midi,
              * and at least one audio channel. *)
             Frame.Zero <: kind.Frame.video &&
             Frame.Zero <: kind.Frame.midi &&
             kind.Frame.audio <> Frame.Zero
          then
            (* In fact we can't be sure that we'll satisfy the content
             * kind, because the stream might be mono or stereo.
             * For now, we let this problem result in an error at
             * decoding-time. Failing early would only be an advantage
             * if there was possibly another plugin for decoding
             * correctly the stream (e.g. by performing conversions). *)
            Some D_stream.create_decoder
          else
            None)

(* Mp4 decoding. *)

let log = Log.make ["decoder";"mp4"]

let mp4_decoder filename =
  let dec = Faad.create () in
  let fd = Unix.openfile filename [Unix.O_RDONLY] 0o644 in
  let closed = ref false in
  let close () =
    if not !closed then
     begin
      Unix.close fd ;
      closed := true
     end
  in
  let resampler = Rutils.create_audio () in
  let mp4,track,samples,sample,sample_freq,chans = 
    try 
      let mp4 = Faad.Mp4.openfile_fd fd in
      let track = Faad.Mp4.find_aac_track mp4 in
      let sample_freq, chans = Faad.Mp4.init mp4 dec track in
      let samples = Faad.Mp4.samples mp4 track in
      let sample = ref 0 in
      mp4,track,samples,sample,sample_freq,chans
    with
      | e -> close (); raise e
  in
  let gen = G.create `Audio in
  let out_ticks = ref 0 in
  (** See decoder.ml for the comments on the value here. *)
  let prebuf =
    Frame.master_of_seconds 0.5
  in
  let fill frame =
     begin try
         while G.length gen < prebuf do
           if !sample >= samples then raise End_of_file;
           let data = Faad.Mp4.decode mp4 track !sample dec in
           incr sample ;
           let content,length =
             resampler ~audio_src_rate:(float sample_freq) data
           in
           G.put_audio gen content 0 (Array.length content.(0))
       done
     with
       | e ->
           log#f 4 "Decoding ended: %s." (Utils.error_message e) ;
           close ()
     end ;
     let offset = Frame.position frame in
     G.fill gen frame ;
     let gen_len = G.length gen in
     out_ticks := !out_ticks + Frame.position frame - offset ;
     (* Compute an estimated number of remaining ticks. *)
     if !sample = 0 then -1 else
       let compression =
         (float (!out_ticks+gen_len)) /. (float !sample)
       in
       let remaining_ticks =
         (float gen_len) +.
         (float (samples - !sample)) *. compression
       in
       int_of_float remaining_ticks
  in
  { Decoder.
     fill = fill ;
     close = close }

(* Get the number of channels of audio in an MP4 file. *)
let get_type filename =
  let dec = Faad.create () in
  let fd = Unix.openfile filename [Unix.O_RDONLY] 0o644 in
    Tutils.finalize ~k:(fun () -> Unix.close fd)
      (fun () ->
        let mp4 = Faad.Mp4.openfile_fd fd in
        let track = Faad.Mp4.find_aac_track mp4 in
        let rate, channels = Faad.Mp4.init mp4 dec track in
           log#f 4
             "Libfaad recognizes %S as MP4 (%dHz,%d channels)."
             filename rate channels ;
           { Frame.
             audio = channels ;
             video = 0 ;
             midi  = 0 })

let () =
  Decoder.file_decoders#register
  "MP4/libfaad"
  ~sdoc:"Use libfaad to decode MP4 if MIME type or file extension \
         is appropriate."
  (fun ~metadata filename kind ->
  let log = log#f 3 "%s" in
  (* Before doing anything, check that we are allowed to produce
   * audio, and don't have to produce midi or video. Only then
   * check that the file seems relevant for MP3 decoding. *)
  if kind.Frame.audio = Frame.Zero ||
     not (Frame.mul_sub_mul Frame.Zero kind.Frame.video &&
          Frame.mul_sub_mul Frame.Zero kind.Frame.midi) ||
     not (Decoder.test_mp4 ~log filename)
  then
    None
  else
    if kind.Frame.audio = Frame.Variable ||
       kind.Frame.audio = Frame.Succ Frame.Variable ||
       Frame.type_has_kind (get_type filename) kind
    then
      Some (fun () -> mp4_decoder filename)
    else
    None)

let get_tags file =
  let fd = Unix.openfile file [Unix.O_RDONLY] 0o644 in
  Tutils.finalize ~k:(fun () -> Unix.close fd)
    (fun () -> 
      let mp4 = Faad.Mp4.openfile_fd fd in
      Array.to_list (Faad.Mp4.metadata mp4))

let () = Request.mresolvers#register "MP4" get_tags