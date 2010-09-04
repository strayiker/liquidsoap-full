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

(** Decode WAV files. *)

let log = Dtools.Log.make ["decoder";"wav"]

(** {1 Generic decoder} *)

exception End_of_stream

let really_input input buf ofs len =
  let rec f len cur =
    if len > 0 then
     begin
      let s,i = input len in
      if i=0 then raise End_of_stream else
      f (len-i) (cur ^ String.sub s 0 i)
     end
    else
       cur
  in
  let ret = f len "" in
  String.blit ret 0 buf ofs len

let input_byte input =
  let s,i = input 1 in
    if i=0 then raise End_of_stream ;
    int_of_char s.[0]

let input input buf ofs len =
  let ret,len = input len in
  String.blit ret 0 buf ofs len ;
  len

let input_ops =
  { Wav.
     really_input = really_input ;
     input_byte = input_byte ;
     input = input ;
     close = fun _ -> ()
  }

module Make (Generator:Generator.S_Asio) =
struct

(* It might be more efficient to write our code for an input
 * channel and use directly the one we have when decoding files
 * or external processes, if we could wrap the input function used
 * for decoding stream (in http and harbor) as an in_channel. *)
let create input =
  let decoder = ref (fun gen -> assert false) in

  let main_decoder converter gen =
    let bytes_to_get = 1024*64 in
    let data,bytes = input bytes_to_get in
      if bytes=0 then raise End_of_stream ;
      let content,length = converter (String.sub data 0 bytes) in
        Generator.set_mode gen `Audio ;
        Generator.put_audio gen content 0 length
  in

  let read_header () =
    let header = Wav.read_header input_ops input in
    let samplesize = Wav.sample_size header in
    let channels = Wav.channels header in
    let samplerate = Wav.sample_rate header in
    let converter =
        Rutils.create_from_wav
          ~samplesize ~channels ()
          ~audio_src_rate:(float samplerate)
    in

      log#f 4
        "WAV header read (%dHz, %dbits), starting decoding..."
        samplerate samplesize ;
      decoder := main_decoder converter

  in
    decoder := (fun _ -> read_header ()) ;
    Decoder.Decoder (fun gen -> !decoder gen)

end

module Generator_plus = Generator.From_audio_video_plus
module Generator = Generator.From_audio_video
module Buffered = Decoder.Buffered(Generator)

(* File decoding *)

module D = Make(Generator)

let get_type filename =
  let header = Wav.fopen filename in
    Tutils.finalize
      ~k:(fun () -> Wav.close header)
      (fun () ->
         let channels =
           let channels  = Wav.channels header in
           let sample_rate = Wav.sample_rate header in
           let ok_message s =
             log#f 4
               "%S recognized as WAV file (%s,%dHz,%d channels)."
                 filename s sample_rate channels ;
           in
           match Wav.sample_size header with
             | 8  -> ok_message "u8"; channels
             | 16 -> ok_message "s16le"; channels
             | _ ->
                log#f 4 "Only 16 and 8 bit WAV files \
                         are supported at the moment.." ;
                0
         in
         { Frame. video = 0 ; midi = 0 ;
                  audio = channels })

let create_file_decoder filename kind =
  let generator = Generator.create `Audio in
    Buffered.file_decoder filename kind D.create generator

let () =
  Decoder.file_decoders#register "WAV"
    ~sdoc:"Decode as WAV any file with a correct header."
    (fun ~metadata filename kind ->
       (* Don't get the file's type if no audio is allowed anyway. *)
       if kind.Frame.audio = Frame.Zero then None else
       let file_type = get_type filename in
         if Frame.type_has_kind file_type kind then
           Some (fun () -> create_file_decoder filename kind)
         else begin
           log#f 3
             "WAV file %S has content type %s but %s was expected."
             filename
             (Frame.string_of_content_type file_type)
             (Frame.string_of_content_kind kind) ;
           None
         end)


let () =
  let duration file =
    let w = Wav.fopen file in
    let ret = Wav.duration w in
    Wav.close w ;
    ret
  in
  Request.dresolvers#register "WAV" duration

(* Stream decoding *)

let conf_mime_types =
  Dtools.Conf.list ~p:(Decoder.conf_mime_types#plug "wav")
    "Mime-types used for guessing WAV format"
    ~d:["audio/vnd.wave"; "audio/wav"; "audio/wave"; "audio/x-wav"]

module D_stream = Make(Generator_plus)

let () =
  Decoder.stream_decoders#register
    "WAV"
    ~sdoc:"Decode a WAV stream with an appropriate MIME type."
     (fun mime kind ->
        let (<:) a b = Frame.mul_sub_mul a b in
          if List.mem mime conf_mime_types#get &&
             kind.Frame.video <: Frame.Zero &&
             kind.Frame.midi <: Frame.Zero &&
             kind.Frame.audio <> Frame.Zero
          then
            (* In fact we can't be sure that we'll satisfy the content
             * kind, because the MP3 stream might be mono or stereo.
             * For now, we let this problem result in an error at
             * decoding-time. Failing early would only be an advantage
             * if there was possibly another plugin for decoding
             * correctly the stream (e.g. by performing conversions). *)
            Some D_stream.create
          else
            None)