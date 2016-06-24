/* This file contains some instantiations of an unknown module that use bit vectors. */

module top(i,o);
    input  [31:0] i;
    output [31:0] o;

    wire [3:0] somebus, someotherbus;
    wire somenet_1,somenet_2;
    wire [29:0] somewidebus;

    assign somewidebus=i[31:2];
    assign o[1]=somenet_1;
    assign o[2]=somenet_2;
    assign o[0]=1'b0;
    assign o[3]=someotherbus[2];
    assign o[28:4]=25'b0;
    assign o[31]=~somenet_1;

    mod instmod_1 (
        .a(somebus),
        .y(somenet_1)
    );

    mod instmod_2 (
        .a(somebus),
        .y(someotherbus[2])
    );

    mod instmod_3 (
        .a(somewidebus[24:21]),
        .y(somenet_2)
    );

    mod instmod_4 (
        .a(i[31:27]),
        .y(o[29])
    );

    mod instmod_5 (
        .a({somenet_1,3'b101,someotherbus[2],somewidebus[2:1]}),
        .y(o[30])
    );

endmodule
