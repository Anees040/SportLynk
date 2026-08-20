# Coding Standards

## Express Backend Rules
- All route handlers: async/await inside try-catch
- Every response: {success:bool, data:any, message:string}
- SQL: ALWAYS parameterized ($1,$2) — never string concatenation
- JWT: sign with {id,email,role}, expire '24h'
- bcrypt: cost factor 12
- Pool config: {connectionString: process.env.DATABASE_URL, ssl: process.env.NODE_ENV==='production' ? {rejectUnauthorized:false} : false}

## Flutter Rules
- NEVER hardcode colors — use AppColors class
- NEVER call API directly in widget — use service class
- State goes in Provider, never setState for shared state
- API calls always show loading state
- Always handle errors with SnackBar
- Always maintain Flutter analyzer at 0 errors/warnings
- Keep UI consistent (use modern curves, standard paddings, and avoiding deprecated methods like withOpacity)

## Folder structure already defined in PROJECT.md
## Colors already defined in PROJECT.md
