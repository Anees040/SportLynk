async function test() {
  try {
    const res = await fetch('http://localhost:3000/api/auth/register/owner', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        name: 'Test Owner',
        phone: '03001239998',
        password: 'password123',
        email: 'test9998@example.com',
        firebaseUid: 'fakeuid123',
        cnicNumber: '3520112345678',
        businessName: 'My Ground',
        groundName: 'My Ground Turf',
        groundType: 'indoor_football',
        sportTypes: ['cricket'],
        city: 'Lahore',
        fullAddress: 'DHA',
        googleMapsLink: '',
        latitude: '',
        longitude: '',
        operatingHoursFrom: '09:00',
        operatingHoursTo: '23:00',
        pricePerHour: '2000',
        alternateContactPhone: '',
        cnicFrontUrl: 'http://example.com/1.jpg',
        cnicBackUrl: 'http://example.com/2.jpg',
        selfieWithCnicUrl: 'http://example.com/3.jpg',
        groundPhotos: ['http://example.com/4.jpg'],
        utilityBillUrl: '',
        ownershipProofUrl: ''
      })
    });
    const data = await res.json();
    console.log(res.status, data);
  } catch (err) {
    console.error(err);
  }
}
test();
