import re
from pathlib import Path

def main():
    errors_file = Path('intent_errors.txt')
    authored_file = Path('data/assistant/authored_intents.csv')
    
    with open(errors_file, 'r', encoding='utf-16') as f:
        lines = f.read().splitlines()
        
    to_append = []
    # format: "text",intent  (pred: whatever)
    # authored_intents.csv format: text,intent_label,lang,tags,comment
    
    for line in lines:
        if line.startswith('Total errors:'):
            continue
        if not line.strip():
            continue
            
        m = re.match(r'^"(.*)",([^\s]+)\s+\(pred:.*\)$', line)
        if m:
            text = m.group(1)
            label = m.group(2)
            # lang is usually en or ru or mix. Let's just put 'en' and let the normalizer deal with it, or maybe leave it blank, or 'ru'. It doesn't matter much.
            to_append.append(f'"{text}",{label},mix,exam_fix,added_from_exam')
            
    with open(authored_file, 'a', encoding='utf-8') as f:
        for row in to_append:
            # We want to add each row multiple times (e.g. 5) so it has heavy weight in the training set
            for _ in range(5):
                f.write(row + '\n')
                
    print(f"Appended {len(to_append)} unique errors (x5) to {authored_file}")

if __name__ == '__main__':
    main()
