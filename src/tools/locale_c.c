#include <caml/misc.h>
#include <caml/mlvalues.h>
#include <locale.h>
#include <stdlib.h>

/* Some libraries mess with locale.
 * In OCaml, locale should always
 * be "C", otherwise float_of_string
 * and other functions do not behave
 * as expected. This issues arises in particular
 * when using telnet commands that need floats
 * and when loading modules in bytecode mode.. */
CAMLprim value liquidsoap_set_locale(value unit)
{
  /* This will prevent further
   * call to setlocale to override
   * "C" */
  setenv("LANG","C",1);
  setenv("LC_ALL","C",1);
  /* This set the locale to "C". */
  setlocale (LC_ALL, "C");
  return Val_unit;
}
