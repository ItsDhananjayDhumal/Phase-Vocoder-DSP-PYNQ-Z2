// atan(2^-i) / (2*pi) * 2^32, i.e. CORDIC micro-rotation angles as 32-bit binary
// angles. Generated from model/pv_params.py:atan_table().
function [31:0] atan_bam;
    input integer i;
    begin
        case (i)
             0: atan_bam = 32'd536870912;
             1: atan_bam = 32'd316933406;
             2: atan_bam = 32'd167458907;
             3: atan_bam = 32'd85004756;
             4: atan_bam = 32'd42667331;
             5: atan_bam = 32'd21354465;
             6: atan_bam = 32'd10679838;
             7: atan_bam = 32'd5340245;
             8: atan_bam = 32'd2670163;
             9: atan_bam = 32'd1335087;
            10: atan_bam = 32'd667544;
            11: atan_bam = 32'd333772;
            12: atan_bam = 32'd166886;
            13: atan_bam = 32'd83443;
            14: atan_bam = 32'd41722;
            15: atan_bam = 32'd20861;
            16: atan_bam = 32'd10430;
            17: atan_bam = 32'd5215;
            default: atan_bam = 32'd0;
        endcase
    end
endfunction
