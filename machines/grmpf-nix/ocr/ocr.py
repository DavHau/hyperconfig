import sys
import pytesseract
from PIL import Image
import io


def main():
    # Read the PNG image from stdin
    image_data = sys.stdin.buffer.read()
    image = Image.open(io.BytesIO(image_data))

    # Use pytesseract to extract text
    text = pytesseract.image_to_string(image)

    # Print the extracted text to stdout
    print(text)


if __name__ == "__main__":
    main()
