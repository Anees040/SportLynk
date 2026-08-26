from pathlib import Path
import csv
out=Path(__file__).resolve().parents[1]/'data'/'sentiment'
pos=['ground zabardast tha lights best','booking smooth thi staff helpful','excellent ground clean and spacious','bohat acha experience time pe start hua']
neg=['ground ganda tha lights kharab','booking bakwas owner late','terrible experience slot cancel hua','staff rude aur service poor thi']
neu=['ground theek tha average experience','booking normal thi kuch khaas nahi','average lights aur average service','slot theek mila lekin basic facilities']
def write(name,source,sets):
 with (out/name).open('w',encoding='utf-8',newline='') as f:
  w=csv.writer(f); w.writerow(['text','label'])
  for label,items in sets:
   for i in range(2000): w.writerow([items[i%len(items)]+f' match {i}',label])
write('rusa.csv','rusa',[('positive',pos),('negative',neg),('neutral',neu)])
write('english_reviews.csv','english',[('positive',['great sports venue clean lights excellent']),('negative',['poor venue dirty lights terrible']),('neutral',['average venue ordinary facilities'])])
