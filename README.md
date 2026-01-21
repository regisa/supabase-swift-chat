# Supabase Swift Chat

A Swift chat application built with Supabase for authentication and real-time features.

## Setup Instructions

### 1. Create a Supabase Project

1. Go to [Supabase Dashboard](https://supabase.com/dashboard) and create a new project
2. Wait for the database to launch

### 2. Set up the Database Schema

You need to set up the database schema for messages. Go to the SQL Editor in your Supabase Dashboard and run this SQL:

```sql

-- Create messages table
create table messages (
  id uuid default uuid_generate_v4() primary key,
  thing_id text not null,
  content text,
  created_at timestamp with time zone default timezone('utc'::text, now()) not null
);

-- Set up Row Level Security (RLS) for messages
alter table messages
  enable row level security;

create policy "Messages are viewable by authenticated users." on messages
  for select using (auth.role() = 'authenticated');

create policy "Authenticated users can insert messages." on messages
  for insert with check (auth.role() = 'authenticated');
```

### 3. Configure the App

1. Get your project URL and API key from your Supabase project's **Connect** dialog (Settings → API)
2. Copy the example configuration file:
   ```bash
   cp SupabaseSwiftChat/Config.example.plist SupabaseSwiftChat/Config.plist
   ```
3. Open `SupabaseSwiftChat/Config.plist` and replace the placeholder values:
   - `SupabaseURL`: Your project URL (e.g., `https://xxxxx.supabase.co`)
   - `SupabaseKey`: Your anon/public key
4. **Important**: Make sure `Config.plist` is added to your Xcode project target (it should be automatically included)

### 4. Create a User Account

Since the app only has sign in (no sign up screen), you need to create a user manually:

1. Go to your Supabase Dashboard → Authentication → Users
2. Click "Add user" and create a user with email and password
3. Use these credentials to sign in to the app

### 5. Run the App

Open the project in Xcode and run it on a simulator or device!

## Features

- ✅ Email + password authentication (sign in only)
- ✅ Display list of thing IDs from messages table
- ✅ Real-time data loading from Supabase
- 🚧 Chat functionality (coming soon)

## Security

This project uses a `Config.plist` file to store sensitive configuration values like your Supabase URL and API key. The `Config.plist` file is **excluded from version control** via `.gitignore` to prevent accidentally committing your credentials.

- ✅ `Config.plist` - Contains your actual credentials (git-ignored)
- 📋 `Config.example.plist` - Template file (committed to git)

When cloning this repository, you'll need to create your own `Config.plist` file from the example template as described in the setup instructions above.

## Tutorial Reference

This app follows the [Supabase Swift Tutorial](https://supabase.com/docs/guides/getting-started/tutorials/with-swift)