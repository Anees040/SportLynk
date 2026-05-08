const router = require('express').Router();
const auth = require('../middleware/authMiddleware');
const checkRole = require('../middleware/roleMiddleware');
const ctrl = require('../controllers/bookingController');

// All booking routes require player auth
router.post('/', auth, checkRole('player'), ctrl.createBooking);
router.get('/my', auth, checkRole('player'), ctrl.getMyBookings);

module.exports = router;
