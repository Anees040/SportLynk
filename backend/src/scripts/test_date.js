const d = new Date('2026-05-10T19:00:00.000Z'); // May 11 00:00 PKT
console.log(d.toLocaleDateString('en-CA'));
console.log(d.toLocaleDateString('en-CA', {timeZone: 'Asia/Karachi'}));
