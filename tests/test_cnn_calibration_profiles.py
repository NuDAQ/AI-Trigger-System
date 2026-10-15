"""Changing only calibration constants changes the public packed CNN input."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CalibrationProfilesTest(unittest.TestCase):
    @unittest.skipUnless(shutil.which('ghdl') and shutil.which('bender'), 'requires local HDL tools')
    def test_calibration_can_be_removed_or_replaced_by_editing_only_constants(self):
        sources = subprocess.check_output(['bender', 'script', 'flist', '-t', 'rtl'], cwd=ROOT, text=True).splitlines()
        hilo = next(Path(p) for p in sources if Path(p).name.lower() == 'pre_trigger_pkg.vhd')
        # Hand-worked native codes for raw samples 0, 64, 128 across channels.
        profiles = [
            ([1_000_000]*4, [0]*4, [[0]*4, [32]*4, [64]*4]),
            ([2_000_000, 4_000_000, 6_000_000, 8_000_000],
             [0, 12_500, -12_500, 25_000],
             [[0, -128, 192, -511], [64, 0, 384, -256], [128, 128, 511, 0]]),
        ]
        for gains, offsets, expected in profiles:
            with self.subTest(gains=gains), tempfile.TemporaryDirectory() as folder:
                tmp = Path(folder)
                rtl = ROOT/'HDL/rtl'
                for filename, constant, values in [
                    ('CNN_INPUT_GAIN_PKG.vhd', 'CNN_INPUT_GAIN_PPM', gains),
                    ('CNN_INPUT_OFFSET_PKG.vhd', 'CNN_INPUT_OFFSET_UV', offsets),
                ]:
                    text = (rtl/filename).read_text()
                    pattern = r'(constant\s+'+constant+r'\s*:.*?:=\s*\()(.*?)(\);)'
                    entries = ', '.join(f'{ch} => {value}' for ch, value in enumerate(values))
                    (tmp/filename).write_text(re.sub(pattern, lambda m: m[1]+entries+m[3], text, flags=re.S))
                checks = []
                for sample, row in enumerate(expected):
                    for ch, code in enumerate(row):
                        lo = (sample*4+ch)*16
                        checks.append(f'assert signed(packed({lo+15} downto {lo})) = to_signed({code},16) severity failure;')
                (tmp/'tb_profile.vhd').write_text('''library ieee;
use ieee.std_logic_1164.all; use ieee.numeric_std.all; use std.env.all;
use work.AI_TRIGGER_PKG.all;
entity tb_profile is end; architecture test of tb_profile is begin process
variable adc : adc_data4_t := (others => (others => (others => '0')));
variable packed : std_logic_vector(LANE_FIFO_WRITE_WIDTH-1 downto 0);
begin
for ch in 0 to 3 loop for sample in 0 to 2 loop
adc(ch)(sample) := std_logic_vector(to_signed(sample*64,12));
end loop; end loop;
packed := pack_cnn_batch(adc);
'''+ '\n'.join(checks)+'''\nstop; wait; end process; end;
''')
                files = [hilo, tmp/'CNN_INPUT_GAIN_PKG.vhd', tmp/'CNN_INPUT_OFFSET_PKG.vhd',
                         rtl/'CNN_INPUT_CALIBRATION_PKG.vhd', rtl/'AI_TRIGGER_PKG.vhd', tmp/'tb_profile.vhd']
                for command in [['ghdl', '-a', '--std=08', *map(str, files)],
                                ['ghdl', '-e', '--std=08', 'tb_profile'],
                                ['ghdl', '-r', '--std=08', 'tb_profile', '--assert-level=error']]:
                    result = subprocess.run(command, cwd=tmp, capture_output=True, text=True)
                    self.assertEqual(result.returncode, 0, result.stdout+result.stderr)


if __name__ == '__main__':
    unittest.main()
