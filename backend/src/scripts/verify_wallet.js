const pool = require('../db/pool');

async function run() {
  const playerId = '42c213c1-0f9a-4ec7-a315-8779dd70ed3c';
  
  const w = await pool.query(
    'SELECT balance, frozen_balance FROM wallets WHERE user_id=$1', [playerId]
  );
  console.log('Wallet:', w.rows[0]);
  
  const b = await pool.query(
    "SELECT id, status, security_deposit FROM bookings WHERE player_id=$1 AND status='confirmed'",
    [playerId]
  );
  console.log('Active confirmed bookings:', b.rows);
  
  // Calculate what frozen_balance SHOULD be
  let expectedFrozen = 0;
  for (const booking of b.rows) {
    expectedFrozen += parseFloat(booking.security_deposit);
  }
  console.log('Expected frozen_balance:', expectedFrozen);
  
  if (parseFloat(w.rows[0].frozen_balance) !== expectedFrozen) {
    console.log('⚠️  MISMATCH! Fixing...');
    await pool.query('UPDATE wallets SET frozen_balance=$1 WHERE user_id=$2', [expectedFrozen, playerId]);
    console.log('✅ Fixed frozen_balance to', expectedFrozen);
  } else {
    console.log('✅ Wallet is consistent!');
  }
  
  pool.end();
}
run().catch(e => { console.error(e); pool.end(); });
