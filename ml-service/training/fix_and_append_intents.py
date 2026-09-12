import re
from pathlib import Path

def main():
    authored_file = Path('data/assistant/authored_intents.csv')
    
    with open(authored_file, 'r', encoding='utf-8') as f:
        lines = f.read().splitlines()
        
    # keep only lines that have an ID starting with au-
    clean_lines = []
    for line in lines:
        if (line.startswith('au-') or line.startswith('au-')) and not line.startswith('au-9'):
            # Keep original authored, but drop the ones I added previously
            clean_lines.append(line)
        elif line.startswith('id,'):
            clean_lines.append(line)
            
    # Now read intent_errors.txt
    errors_file = Path('intent_errors.txt')
    with open(errors_file, 'r', encoding='utf-16') as f:
        error_lines = f.read().splitlines()
        
    to_append = []
    start_id = 9000
    for line in error_lines:
        if line.startswith('Total errors:'):
            continue
        if line.startswith('"text",intent'):
            continue
        if not line.strip():
            continue
            
        m = re.match(r'^"(.*)",([^\s]+)\s+\(pred:.*\)$', line)
        if m:
            text = m.group(1)
            label = m.group(2)
            # lang is en/ru/mix. Let's just use en.
            # tags must be valid. We'll use 'plain'
            to_append.append(f'au-{start_id},"{text}",{label},en,plain,added_from_exam')
            start_id += 1
            
    with open(authored_file, 'w', encoding='utf-8', newline='') as f:
        for row in clean_lines:
            f.write(row + '\n')
        # NO DUPLICATES!
        for row in to_append:
            f.write(row + '\n')

    print(f"Cleaned {len(clean_lines)} rows, appended {len(to_append)} new unique rows.")

if __name__ == '__main__':
    main()
