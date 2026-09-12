import pandas as pd
import joblib
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

def find_errors():
    model = joblib.load('models/intent_latest.joblib')['model']
    exam = pd.read_csv('data/assistant/assistant_test.csv', header=None, names=['id', 'text', 'label', 'lang', 'tags', 'comment'])
    
    texts = exam['text'].tolist()
    y_true = exam['label'].tolist()
    y_pred = model.predict(texts)
    
    errors = []
    for t, true, pred in zip(texts, y_true, y_pred):
        if true != pred:
            errors.append((t, true, pred))
            
    print(f"Total errors: {len(errors)}")
    for t, true, pred in errors:
        print(f'"{t}",{true}  (pred: {pred})')

if __name__ == '__main__':
    find_errors()
