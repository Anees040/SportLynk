const router = require('express').Router();
const auth = require('../middleware/authMiddleware');
const checkRole = require('../middleware/roleMiddleware');
const ctrl = require('../controllers/ownerController');

// All owner routes require auth + owner role
router.use(auth, checkRole('owner'));

router.get('/venues', ctrl.getOwnerVenues);
router.post('/venues', ctrl.createVenue);
router.post('/venues/:id/slots', ctrl.createSlots);
router.get('/bookings', ctrl.getOwnerBookings);
router.put('/bookings/:id/approve', ctrl.approveBooking);
router.put('/bookings/:id/reject', ctrl.rejectBooking);
router.post('/checkin', ctrl.verifyCheckIn);
router.patch('/checkin/decide', ctrl.submitCheckInDecision);

module.exports = router;
