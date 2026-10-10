# TSS-752 hardware

This page lists the parts of the TSS-752 and how mainline Linux uses them.
The board device tree is `imx53-crestron-tss752.dts` of the kernel branch
`tsx-xx50-lts`. Its comments tag each value as DECODED (read from the vendor
kernel), LIKELY, GUESS or TESTED.

## Parts

| Status | Meaning |
|---|---|
| Tested | Checked on the panel. |
| Implemented | The driver works and its registers are correct. A person did not check the result by eye or by ear. |
| Does not work | Linux cannot use the part. |

| Part | Linux | Status |
|---|---|---|
| SoC | NXP i.MX53, one Cortex-A8 core, 1 GiB RAM in two banks | Tested |
| Boot | Stock U-Boot 2009.08 on the SD card (eSDHC1) | Tested |
| Ethernet | FEC in RMII mode, generic PHY at MDIO address 0, PHY reset GPIO7_6 | Tested, 100 Mbit |
| Display | 800x480 RGB666 panel on IPU DI0, `imx-drm`, connector `card0-DPI-1` | Tested |
| Backlight | PWM2, 20 kHz, inverted, `pwm-backlight` (0 to 255) | Tested |
| Touch | FT5x06 at I2C3 0x38, `edt-ft5x06`, interrupt GPIO3_4 falling edge | Tested |
| Touch keys | Key zones of the touch controller, `touch-overlay` | Tested |
| PMIC | DA9053 at I2C1 0x48, `da9052` (regulators, onkey, hwmon) | Tested |
| CPU frequency | `cpufreq-dt`, 167 MHz to 1 GHz | Tested |
| Light bars | Two TLC59116 at I2C1 0x60 and 0x61, `leds-tlc591xx` | Tested for red and green. Implemented for blue. |
| Audio playback | TLV320AIC3204 at I2C2 0x18, SSI2, `simple-audio-card` | Implemented: the clocks, the rates and the amplifier enable are correct. Nobody has checked the speaker sound. |
| Audio capture | Digital (PDM) microphone on the codec | Does not work |
| GPU | Z430 (Adreno 200), `drm/msm` a2xx, render node `renderD128` | Tested |
| EEPROM | M24M01 at I2C2 0x54, `at24`, read only | Tested |
| Watchdog | WDOG1, `imx2-wdt`, busybox watchdog with 60 s | Tested |
| Back button | Hardware reset of the panel | Software cannot read it |

The panel has no USB port, no Wi-Fi, no Bluetooth, no camera, no presence
sensor and no ambient light sensor.

## Touch

The touch controller reports as "generic ft5x06" and gives no resolution.
The device tree sets the touch space of the vendor kernel:
`touchscreen-size-x = <1600>` and `touchscreen-size-y = <1024>`. The axes
have no swap and no inversion. The driver reports X from 0 to 1599 and Y
from 0 to 1023 for the 800x480 picture.

## Touch keys

The glass has five printed keys to the right of the picture. The keys are
not lit. They are zones of the touch controller. The `touch-overlay` node of
the touch controller holds the key zones of the vendor kernel. The driver
reports a touch in a key zone as a key event and a touch on the picture as a
touch event. It drops a touch outside the picture and the key zones. A touch
that starts on the picture never presses a key.

| Key | Symbol | Name | X | Y | Key code |
|---|---|---|---|---|---|
| 1 (top) | power | `power` | 1601..2047 | 28..126 | `KEY_F13` |
| 2 | home | `home` | 1601..2047 | 251..349 | `KEY_F14` |
| 3 | lights | `lights` | 1601..2047 | 472..570 | `KEY_F15` |
| 4 | up | `up` | 1601..2047 | 683..781 | `KEY_F16` |
| 5 (bottom) | down | `down` | 1601..2047 | 915..1013 | `KEY_F17` |

The names are the key names of `/etc/tsx/buttons-board.conf` and of the
panel app.

## Light bars

The panel has an RGB light bar on each side. Each bar has its own TLC59116
LED driver on I2C1: 0x60 drives the left bar and 0x61 drives the right bar.
Each bar has four RGB LEDs. The outputs 0 to 11 drive these LEDs in the
order green, blue, red for each LED. The outputs 12 to 15 have no LED. The
front keys have no LEDs.

The device tree gives one LED device for each output, for example
`red:lightbar-left-1`, and one multicolor LED device for each bar. Use the
multicolor devices. They set all four RGB LEDs of a bar to the same color.
While a multicolor device exists, the LED devices of its outputs are read
only.

| Device | Bar |
|---|---|
| `/sys/class/leds/rgb:lightbar-left` | left bar (TLC59116 at 0x60) |
| `/sys/class/leds/rgb:lightbar-right` | right bar (TLC59116 at 0x61) |

`multi_index` shows the color of each of the 12 values in
`multi_intensity`: `green blue red` four times. `max_brightness` is 256.
To set a color, write 12 values to `multi_intensity`, then write
`brightness`. This example sets the left bar to red at a quarter of the full
level:

```sh
L=/sys/class/leds/rgb:lightbar-left
echo "0 0 256 0 0 256 0 0 256 0 0 256" > $L/multi_intensity
echo 64 > $L/brightness
```

Red and green are checked on the panel by eye. Blue has the correct
register values, but nobody has checked it by eye.

Write `0` to `brightness` to turn the bar off. The bars are off after the
start. The panel app shows the bars in Home Assistant as "Light bar left"
and "Light bar right".

## Audio

The panel has a TLV320AIC3204 codec at I2C2 0x18 and a speaker amplifier on
the line outputs (LOL and LOR) of the codec. The sound card is
`tss752-aic3204` (`simple-audio-card`).

| Part | Value |
|---|---|
| CPU side | SSI2. The AUDMUX connects internal port 2 to external port 5 (the AUD5 pads). |
| Format | I2S. The codec makes the bit clock and the frame clock. |
| MCLK | CCM SSI_EXT1 on the GPIO_0 pad, 24 MHz from the 24 MHz oscillator |
| Codec reset | GPIO2_10, active low. The codec driver releases it at the start. |
| Amplifier enable | GPIO1_4, high = on. The amplifier is on only while a stream plays. |
| DMA | SDMA with the scripts in the SDMA ROM. The SDMA firmware file is not necessary. |

The kernel branch has a fix in `clk-imx5.c` for this clock path: the parent
list of `ssi_apm` names `lp_apm` correctly. Without it, the kernel cannot
select the 24 MHz oscillator for MCLK.

The codec starts with the line outputs off. Set the mixer before you play:

```sh
amixer -c 0 sset 'LOL Output Mixer L_DAC' on
amixer -c 0 sset 'LOR Output Mixer R_DAC' on
amixer -c 0 sset 'LO DAC' on
amixer -c 0 sset 'LO Driver Gain' 6     # 0 dB
amixer -c 0 sset PCM 67                 # -30 dB
```

The vendor firmware sets the line output gain to +20 dB. Start with a low
level and increase it in small steps. The playback rates 8, 16, 44.1 and
48 kHz play at the correct speed. Nobody has checked the speaker sound by
ear.

The microphone is a digital (PDM) microphone on the codec. The
`tlv320aic32x4` driver has no digital microphone input, so capture gives
silence. `tsx-hw` reports `MIC=no`.

Do not unbind the codec driver. An unbind and a new bind of `tlv320aic32x4`
cause a kernel oops.

## CPU and power rails

The stock U-Boot starts the CPU at 1 GHz with 1.25 V on the CPU supply.
`BogoMIPS 66.66` in the kernel log comes from the timer, not from the CPU
clock. Read the speed in `scaling_cur_freq`.

The DA9053 rail BUCKCORE (`buck1`, named `vddgp`) supplies the CPU core.
The kernel sets it from 0.9 V to 1.25 V, the lowest and the highest vendor
value. The other rails have no voltage limits in the device tree and stay
on. The kernel does not change them.

| Rail | Voltage at boot | Use |
|---|---|---|
| buck1 (`vddgp`) | 1.25 V | CPU core. cpufreq sets it. |
| buck2 | 1.3 V | Not known. Not changed. |
| buck3 | 1.225 V | Not known. Not changed. |
| buck4 | 2.5 V | Not known. Not changed. |
| ldo1, ldo2, ldo5, ldo6, ldo10 | 1.3 V | Not known. Not changed. |
| ldo3 | 3.3 V | Not known. Not changed. |
| ldo4 | 2.775 V | Not known. Not changed. |
| ldo7 | 2.75 V | Not known. Not changed. |
| ldo8 | 1.8 V | Not known. Not changed. |
| ldo9 | 1.5 V | Not known. Not changed. |

The operating points are the vendor table for 1 GHz parts:

| Frequency | CPU supply |
|---|---|
| 1000 MHz | 1.25 V |
| 900 MHz | 1.25 V |
| 800 MHz | 1.1 V |
| 600 MHz | 1.1 V |
| 400 MHz | 0.95 V |
| 333 MHz | 0.95 V |
| 167 MHz | 0.9 V |

The panel has no CPU temperature sensor that Linux can read. Mainline has no
thermal driver for the i.MX53. The DA9053 hwmon device shows the ADC
voltages. Its junction temperature (`temp8`) is not valid on this board.

## GPU

The kernel builds `drm/msm` as a module, with the MDP4, MDP5 and DPU display
parts off. The display stays on `imx-drm`. The GPU runs at 200 MHz. The
firmware files are `qcom/yamato_pm4.fw` and `qcom/yamato_pfp.fw` from Alpine
`linux-firmware-qcom`. `/etc/modules-load.d/tsx-xx50.conf` loads `msm` at
boot.

Mesa (freedreno) pairs the display with the render node through
`imx-drm_dri.so`. The renderer is "FD200", OpenGL ES 2.0. `kmscube` runs at
60 frames per second. The panel app does not use the GPU: on the Z430, LVGL
draws faster on the CPU.

## Browser

The xx50 has no browser kiosk. The Home Assistant frontend needs more CPU
time than one Cortex-A8 core has: a dashboard keeps the CPU at 100 percent.
The panel app shows the cards instead.

## I2C devices

| Bus | Address | Device |
|---|---|---|
| I2C1 | 0x48 | DA9053 PMIC (driver `da9052`) |
| I2C1 | 0x60, 0x61 | TLC59116 LED drivers of the light bars (driver `leds-tlc591xx`) |
| I2C2 | 0x18 | TLV320AIC3204 audio codec (driver `tlv320aic32x4`) |
| I2C2 | 0x54, 0x55 | M24M01 EEPROM (driver `at24`) |
| I2C3 | 0x38 | FT5x06 touch controller (driver `edt-ft5x06`) |

Before the LED driver starts, the TLC59116 parts also answer at 0x68, their
all-call address. The driver turns it off.

## Hardware facts file

`/usr/local/sbin/tsx-hw` writes the hardware facts to `/run/tsx/hw.conf`
for the tools of tsx-linux-common:

| Key | Value | Reason |
|---|---|---|
| `MIC` | `no` | The codec driver has no digital microphone input. |
| `BT`, `WIFI`, `CAMERA` | `no` | The panel does not have these parts. |
| `PRESENCE` | `no` | The panel has no presence sensor. |
| `LIGHT` | `no` | The panel has no ambient light sensor. |
| `LEDBAR` | `no` | The panel has no USB port, so it cannot have the USB LED bar. The built-in light bars are LED devices. |

## Messages that are not errors

| Message | Cause |
|---|---|
| `ramoops: uncorrectable error in header` | The ramoops area is empty on the first start after power-on. |
| `Initramfs unpacking failed`, `rdinit=/init failed` | The ramdisk is a placeholder for the stock U-Boot. It holds no `/init`. |
| `coda ... vpu_fw_imx53.bin failed` | The image has no VPU firmware. The image does not use the VPU. |
| `failed to find fsl,imx53-iim regmap` | The IIM node in `imx53.dtsi` is not a syscon. This message shows on all i.MX53 boards. |
| `panel-simple panel: Specify missing bus_format` | The panel node sets no bus format. The display works. |
| `imx-sdma ... external firmware not found, using ROM firmware` | The image has no SDMA firmware file. The SSI uses scripts in the SDMA ROM. |
| `simple-amplifier audio-amplifier: supply VCC not found, using dummy regulator` | The amplifier supply is always on. The device tree gives no supply for it. |

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| A reboot does not complete after a kernel oops | The kernel stops in the device shutdown and still feeds the watchdog. | Remove the PoE power, or push the back button (hardware reset). |
| A short tap on the dark screen does nothing | The touch controller is in its monitor mode. | Check that `tsx-touch` runs (`rc-service tsx-touch status`). |
| `temp8` of the DA9053 shows about -126 °C | The PMIC does not measure the junction temperature on this board. | Ignore the value. |
