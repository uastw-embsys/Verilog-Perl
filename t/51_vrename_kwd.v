// DESCRIPTION: Verilog-Perl: Example Verilog for testing package
// This file ONLY is placed into the Public Domain, for any use,
// without warranty, 2010-2012 by Wilson Snyder.

module 51_vrename_kwd;
   wire do = foo;
   wire \esc[ape]d = foo;
   wire \do = foo;
   initial $display("foo");
   initial $display("foo.foo");
   initial $display("baz_foo");
   initial $display("foo_baz");
endmodule
