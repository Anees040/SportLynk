const router = require('express').Router();
const auth = require('../middleware/authMiddleware');
const ctrl = require('../controllers/authController');

router.post('/register/player', ctrl.registerPlayer);
router.post('/register/owner', ctrl.registerOwner);
router.post('/login', ctrl.login);
router.post('/verify-phone', ctrl.verifyPhone);
router.post('/forgot-password/send-otp', ctrl.forgotPasswordSendOtp);
router.post('/forgot-password/reset', ctrl.forgotPasswordReset);
router.get('/me', auth, ctrl.getMe);

module.exports = router;
