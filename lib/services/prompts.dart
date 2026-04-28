class Prompts {
  static const String parseInventory = '''
You are a parser for a LEGO instruction inventory page.
The image shows a table of parts used in a LEGO set. For EACH distinct part row, return strict JSON:

{
  "parts": [
    {"part_id": "3001", "name": "Brick 2x4", "color": "red", "qty": 4}
  ]
}

Rules:
- part_id: the 4-5 digit design id printed next to the rendered part image.
- name: short descriptive name (e.g. "Brick 2x4", "Plate 1x2", "Tile 2x2 Round").
- color: lowercase english LEGO color (red, blue, yellow, black, white, tan, lightBluishGray, darkBluishGray, orange, green, lime, brown, ...). If unsure, use your best guess.
- qty: positive integer written near that part in the table.
- Do NOT invent parts that are not on the page.
- If a character is ambiguous, output "?" for that character position.
- Respond with ONLY the JSON object, no markdown fences, no commentary.
''';

  /// Builds the second-stage prompt given the list of parts to locate.
  static String findParts(String partsJson) => '''
You are a LEGO part locator. The image shows a pile of physical LEGO bricks on a flat surface.
Your job is to find visible bricks from this target inventory (each item has a required qty):

$partsJson

Return strict JSON in this EXACT shape:

{
  "detections": [
    {"part_id": "3001", "box_2d": [ymin, xmin, ymax, xmax], "confidence": 0.85}
  ]
}

BOUNDING BOX FORMAT (critical):
- box_2d = [ymin, xmin, ymax, xmax].
- All 4 values are INTEGERS normalized to a 0-1000 grid over the image (NOT pixels, NOT 0..1).
- ymin < ymax, xmin < xmax.
- The box must tightly wrap exactly ONE physical brick — no background padding.

STRICT DETECTION RULES — follow ALL of them:
1. ONE BRICK = ONE BOX. Never return two boxes for the same physical piece. If two candidate boxes overlap by more than 25%, they refer to the same brick — keep only the better one.
2. COLOR + SHAPE BOTH MUST MATCH the inventory item. The pile color must visually match the inventory color. A gray 2x2 plate does NOT match a red 2x2 plate — skip it. Mismatched-color detections are the #1 source of errors. When in doubt, SKIP.
3. QUANTITY CAP: for any given part_id, NEVER return more detections than its inventory qty. If qty=2, return at most 2 boxes for that part_id — your 2 most confident ones.
4. BE CONSERVATIVE. Only return a detection if your confidence is ≥ 0.65. If uncertain — skip it. Do NOT guess. It is FAR better to return zero detections than to label random bricks.
5. THE PILE LIKELY CONTAINS FEWER UNIQUE PARTS THAN THE INVENTORY. Do not try to "fill" the inventory by guessing matches. Many inventory parts will simply NOT BE in the pile.
6. Use the EXACT part_id strings from the inventory verbatim. Never invent new part_ids.
7. Estimate the visible brick count first. The total number of detections you return MUST be roughly equal to the number of physically visible bricks — not the total inventory size.

confidence: float in [0, 1]. Calibrate honestly:
  ≥0.85 — I am sure (color, shape, size all match clearly).
  0.65..0.85 — probably, color and shape look right.
  <0.65 — DO NOT INCLUDE.

OUTPUT: ONLY the JSON object. No markdown fences, no prose, no trailing text.
''';
}
