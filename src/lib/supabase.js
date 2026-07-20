import { createClient } from "@supabase/supabase-js";

// Single source of truth for the Supabase project this site talks to.
// Previously the URL/anon key were hardcoded and duplicated separately
// inside index.html and hq.html — now every page imports from here.
export const SUPABASE_URL = import.meta.env.VITE_SUPABASE_URL;
export const SUPABASE_ANON_KEY = import.meta.env.VITE_SUPABASE_ANON_KEY;

let client = null;

export function getSupabaseClient() {
  if (!client) {
    client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  }
  return client;
}
