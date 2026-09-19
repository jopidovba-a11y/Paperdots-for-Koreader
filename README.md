# Paper Dots

A KOReader plugin that adds a subtle paper-like dot texture to the screen.

The dots are drawn only over near-white pixels right before each screen refresh, so text and images stay untouched.

<p align="center">
  <table width="100%" style="border-collapse: collapse; margin-left: auto; margin-right: auto;">
    <tr>
      <td align="center" style="padding: 10px; vertical-align: top;">
        <img width="1072" height="1448" style="width: 100%; max-width: 300px;" alt="Vista de lectura - Configuración" src="https://github.com/user-attachments/assets/6d8ecc08-fb67-4081-a54b-a4b08a13b785" />
      </td>
      <td align="center" style="padding: 10px; vertical-align: top;">
        <img width="720" height="1600" style="width: 100%; max-width: 300px;" alt="Captura de pantalla de la interfaz 1" src="https://github.com/user-attachments/assets/ca11ca4b-6184-4305-ba5f-6fd2f5b1a772" />
      </td>
      <td align="center" style="padding: 10px; vertical-align: top;">
        <img width="1072" height="1448" style="width: 100%; max-width: 300px;" alt="Vista de lectura - Inicio 2" src="https://github.com/user-attachments/assets/a69fd446-9c2b-4112-ac6b-36740cd258d6" />
      </td>
    </tr>
  </table>
</p>




## Features

- Adjustable density, dot size, and dot brightness range
- Apply to the whole device or only while a book is open

## Installation

1. Copy the `paperdots.koplugin` folder into KOReader's `plugins` directory:

       koreader/plugins/paperdots.koplugin/
    
2. Restart KOReader.

## Usage

Open a book, tap the top of the screen, and go to the second tab (Document) > Paper dots.

- Enable: turns the effect on or off
- Only inside books: skips the file browser and other screens
- Density: percentage of pixels covered by dots
- Dot size: size of each dot in pixels
- Darkest dot / Lightest dot: brightness range of the dots (0 = black)
- Reset to defaults

## Notes

- Tested on Kobo and Android.
- On e-ink screens, 1 px dots can be hard to see. Try a dot size of 2 and a higher density.
- High densities may make page turns slower on low-power devices.
- Screenshots taken inside KOReader will include the dots.
